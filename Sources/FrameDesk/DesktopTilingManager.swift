import AppKit
import ApplicationServices
import SwiftUI
import FrameDeskCore

@MainActor
final class DesktopTilingManager: ObservableObject {
    @Published private(set) var file = DesktopTilingFile()
    @Published private(set) var displays = Display.all
    @Published private(set) var canUndo = false
    @Published private(set) var status = "Choose a grid, then enable snapping."
    @Published var error: String?
    @Published var editorScope = "desktop"
    @Published private(set) var sceneResolution: SceneResolution = .unconfigured
    @Published private(set) var sceneDisplays = Display.all.map(\.sceneDisplay)
    @Published private(set) var detectingScene = false
    private var sceneTask: Task<Void,Never>?
    private var displayConfiguration:[DisplayConfiguration]=[]
    let store: DesktopTilingStore
    private var readable = true
    private var started = false
    private var automaticSnapping = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var panels: [String: GridPanel] = [:]
    private var drag: Drag?
    private var generation = 0
    private var undo: Undo?
    private var liveAssignments: [String: [(element: AXUIElement, placementID: UUID)]] = [:]
    private var lastExternalPID: pid_t?
    private var lastDragUpdate: TimeInterval = 0
    // Used only by the opt-in native diagnostic, never to generate production events.
    var onDragHighlight: ((String, Int) -> Void)?
    var onDiagnosticEvent: ((String) -> Void)?
    private struct Drag { let window: LiveWindow; let origin: CGRect; var moved = false }
    private struct Undo { let scope: String; let profile: DesktopProfile; let windows: [LiveWindow]; let displays: [String: Box]; let context: SceneContext }
    private var displaySnapshot: [String: Box] { Dictionary(uniqueKeysWithValues: displays.map { ($0.id, Box($0.frame)) }) }

    var activeName: String { currentProfile().name }
    var enabled: Bool { automaticSnapping || file.enabled }
    var showGrid: Bool { file.showGrid }
    var requireShift: Bool { !automaticSnapping && file.requireShift }
    var overlayCount: Int { panels.values.filter(\.isVisible).count }
    var overlayWindows: [NSWindow] { Array(panels.values) }
    init(directory: URL) {
        store = DesktopTilingStore(url: directory.appendingPathComponent("desktop-tiling.json"))
        displayConfiguration=displays.map(DisplayConfiguration.init).sorted { $0.id<$1.id }
        do { file = try store.load(); editorScope = file.activeScope }
        catch { readable = false; self.error = "\(error.localizedDescription) Location: \(store.url.path)" }
    }
    func startIfInteractive() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains(where: { $0.hasSuffix("check") || $0.contains("snapshot") }) else { return }
        if !started { TilingDiagnostics.traceManualDropsIfRequested(manager: self) }
        // Isolated fixture runs keep using their explicit enabled and Shift flags.
        start(automaticallySnap: !arguments.contains("--fixture-windows-only"))
    }
    func start(automaticallySnap: Bool = false) {
        guard !started else { return }
        started = true
        automaticSnapping = automaticallySnap
        lastExternalPID = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0.processIdentifier }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMonitoring() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.lastExternalPID = app.processIdentifier }
        })
        refreshSceneDetection()
        refreshMonitoring()
        if file.enabled { restoreSavedWindows() }
    }
    func stop() {
        started = false
        sceneTask?.cancel(); sceneTask=nil; detectingScene=false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        cancelDrag()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        panels.values.forEach { $0.orderOut(nil) }; panels.removeAll()
    }
    var hasDisplayScenes: Bool { !(file.scenes?.scenes.isEmpty ?? true) }
    var currentContext: SceneContext {
        if case .recognized(let context)=sceneResolution { return context };return .unassigned
    }
    var currentSceneName: String {
        file.scenes?.scenes.first { $0.id==currentContext.sceneID }?.name ?? "Unassigned"
    }
    var sceneStatus: String {
        if detectingScene { return "Detecting display setup…" }
        switch sceneResolution {
        case .unconfigured:return "No saved scene"
        case .unknown:return "Unrecognized setup · saved scenes are protected"
        case .ambiguous:return "Multiple scenes match · choose a scene"
        case .recognized:return "\(currentSceneName) · \(sceneDisplays.count) display\(sceneDisplays.count == 1 ? "" : "s")"
        }
    }
    private var bindingKey: String { file.activeScope+"|"+currentContext.key }
    func displayKey(_ id:String)->String { file.scenes?.canonicalID(id) ?? id }
    func sceneBrowserBounds(scope:String)->Box? {
        guard hasDisplayScenes,currentContext != .unassigned else { return nil }
        let candidates=currentProfile(scope:scope).windows.filter { $0.bundleID==EdgeBrowser.bundleID }
        guard candidates.count==1,let placement=candidates.first,
              let display=displays.first(where: { displayKey($0.id)==placement.displayID }) else { return nil }
        let frame=Geometry.expanded(placement.normalized,in:display.visible)
        return Box(Geometry.flipped(frame,primaryTop:Display.primaryTop))
    }
    func currentProfile(scope:String?=nil)->DesktopProfile {
        let key=scope ?? file.activeScope
        return file.profile(scope:key,context:currentContext) ?? DesktopProfile(name:file.profiles[key]?.name ?? "Desktop")
    }
    func refreshSceneDetection(snapshot:[SceneDisplay]?=nil,restore:Bool=false) {
        let previous=currentContext
        sceneDisplays=snapshot ?? displays.map(\.sceneDisplay)
        let result=file.scenes?.resolve(sceneDisplays) ?? .unconfigured
        if case .recognized(let context)=result {
            var next=file;next.scenes?.ensureVariant(context,connected:sceneDisplays)
            if next != file && !commit(next) { sceneResolution = .unknown;cancelDrag();undo=nil;canUndo=false;return }
        }
        sceneResolution=result
        if previous != currentContext { cancelDrag();undo=nil;canUndo=false }
        refreshOverlays();status=sceneStatus
        if restore && enabled && file.scenes?.autoRestore==true && currentContext != .unassigned { restoreSavedWindows() }
    }
    @discardableResult
    func saveScene(_ scene:DisplayScene,labels:[String:String]=[:])->Bool {
        guard !detectingScene else { return false }
        let name=scene.name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty else { error="Enter a scene name.";return false }
        guard !(file.scenes?.scenes.contains { $0.id != scene.id && $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? false) else { error="A scene already uses that name. Choose another name.";return false }
        var next=file;var library=next.scenes ?? DisplaySceneLibrary()
        var normalized=scene;normalized.name=name
        library.register(normalized,connected:sceneDisplays,legacy:next.profiles)
        for (id,name) in labels {
            let trimmed=name.trimmingCharacters(in:.whitespacesAndNewlines)
            if !trimmed.isEmpty { library.knownDisplays[id]?.name=trimmed }
        }
        next.scenes=library
        guard commit(next) else { return false }
        error=nil;refreshSceneDetection(snapshot:sceneDisplays);return true
    }
    func setAutomaticSceneRestore(_ value:Bool) {
        var next=file;var library=next.scenes ?? DisplaySceneLibrary();library.autoRestore=value;next.scenes=library
        _=commit(next)
    }
    func chooseScene(_ id:UUID) {
        var next=file;guard var library=next.scenes else { return }
        library.preferences[DisplaySceneLibrary.token(library.canonical(sceneDisplays))]=id
        let result=library.resolve(sceneDisplays)
        guard case .recognized(let context)=result,context.sceneID==id else { error="That scene does not match these displays. Edit its required/optional displays first.";return }
        next.scenes=library;guard commit(next) else { return }
        refreshSceneDetection(snapshot:sceneDisplays);restoreSavedWindows()
    }
    @discardableResult
    func mapDisplay(_ rawID:String,to canonicalID:String)->Bool {
        var next=file
        guard var library=next.scenes,library.knownDisplays[canonicalID] != nil,
              library.knownDisplays[rawID]==nil,rawID != canonicalID else { return false }
        guard let current=sceneDisplays.first(where:{ $0.id==rawID }),current.builtIn==library.knownDisplays[canonicalID]?.builtIn else { error="Choose a saved display of the same type (built-in or external).";return false }
        library.aliases[rawID]=canonicalID;next.scenes=library
        guard Set(library.canonical(sceneDisplays).map(\.id)).count==sceneDisplays.count else { error="Two connected displays cannot share the same saved identity.";return false }
        guard commit(next) else { return false };refreshSceneDetection(snapshot:sceneDisplays);return true
    }
    @discardableResult
    func removeDisplayAlias(_ rawID:String)->Bool {
        var next=file
        guard next.scenes?.aliases.removeValue(forKey:rawID) != nil else { return false }
        guard commit(next) else { return false }
        error=nil;refreshSceneDetection(snapshot:sceneDisplays);return true
    }
    func displayLabel(_ display: Display) -> String {
        if let name = file.scenes?.knownDisplays[displayKey(display.id)]?.name { return name }
        if displays.filter({ $0.name == display.name }).count > 1,
           let index = displays.firstIndex(where: { $0.id == display.id }) { return "\(display.name) · Display \(index + 1)" }
        return display.name
    }
    func usesOriginalArrangement(for activity: Activity) -> Bool {
        !hasDisplayScenes && currentProfile(scope: activity.id.uuidString).capturedArrangement != true
    }
    func savedWindows(for activity: Activity) -> [Placement] {
        let tiled = currentProfile(scope: activity.id.uuidString).windows
        if usesOriginalArrangement(for: activity) {
            let matches = WindowMatching.match(saved: activity.windows, live: tiled)
            let replaced = Set(matches.map(\.saved))
            return activity.windows.enumerated().filter { !replaced.contains($0.offset) }.map(\.element) + tiled
        }
        return currentContext == .unassigned && hasDisplayScenes ? [] : tiled
    }
    var canSaveArrangement: Bool {
        !detectingScene && (!hasDisplayScenes || currentContext != .unassigned)
    }
    func saveArrangement(_ selected: [LiveWindow], for activity: Activity, context: SceneContext,
                         configuration: [DisplayConfiguration]) -> Bool {
        guard canSaveArrangement, context == currentContext,
              configuration == Display.all.map(DisplayConfiguration.init) else {
            error = "The display setup changed. Cancel and choose windows again for the current setup."
            return false
        }
        do {
            let visible = try WindowManager.scan(bundleIDs: Set(selected.map(\.placement.bundleID)))
            let current = selected.compactMap { chosen in visible.first { CFEqual($0.element, chosen.element) } }
            guard !current.isEmpty, current.count == selected.count else {
                error = "A selected window is no longer visible. Refresh the window list and try again."
                return false
            }
            let scope = activity.id.uuidString
            var profile = currentProfile(scope: scope)
            profile.name = activity.name
            profile.capturedArrangement = true
            var placements: [Placement] = []
            for window in current {
                guard let display = displays.first(where: { $0.id == window.placement.displayID }),
                      display.visible.insetBy(dx: -1, dy: -1).contains(window.frame) else {
                    error = "Move each selected window fully onto one display, then save again."
                    return false
                }
                var placement = window.placement
                placement.displayID = displayKey(display.id)
                placement.normalized = Geometry.normalized(window.frame.intersection(display.visible), in: display.visible)
                placements.append(placement)
            }
            profile.windows = placements
            var next = file
            guard next.setProfile(profile, scope: scope, context: context), commit(next) else { return false }
            liveAssignments[scope + "|" + context.key] = zip(current, placements).map { ($0.0.element, $0.1.id) }
            undo = nil
            canUndo = false
            error = nil
            status = "Saved \(placements.count) window\(placements.count == 1 ? "" : "s") for \(activity.name)."
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    func grid(scope: String? = nil, display: String) -> TileGrid {
        currentProfile(scope:scope).grids[displayKey(display)] ?? TileGrid()
    }
    @discardableResult
    private func commit(_ next: DesktopTilingFile) -> Bool {
        guard readable else { error = "The existing desktop tiling file could not be read. It has not been overwritten. Location: \(store.url.path)"; return false }
        do { try store.save(next); file = next; return true }
        catch { self.error = "Could not save desktop tiling: \(error.localizedDescription) Your previous saved settings are intact."; return false }
    }
    func setEnabled(_ value: Bool) {
        var next = file; next.enabled = value
        guard commit(next) else { return }
        cancelDrag(); refreshMonitoring()
        status = value ? (WindowManager.allowed ? "Drag a window by its title bar into a zone. Hold Option to bypass." : "Enable Accessibility in Settings to snap windows.") : "Snapping paused. Saved grids are kept."
    }
    func setShowGrid(_ value: Bool) {
        var next = file; next.showGrid = value
        if commit(next) { refreshOverlays() }
    }
    func setRequireShift(_ value: Bool) {
        var next = file; next.requireShift = value
        if commit(next) { cancelDrag() }
    }
    @discardableResult
    func setGrid(_ grid: TileGrid, scope: String, name: String, display: String, context: SceneContext? = nil) -> Bool {
        guard grid.isValid else { return false }
        guard !detectingScene, context == nil || context == currentContext else {
            error="The display scene changed while editing. Your draft is kept. Reconnect the original setup to save it, or cancel and edit this scene."; return false
        }
        var next = file
        var profile = currentProfile(scope:scope)
        profile.name = name; profile.grids[displayKey(display)] = grid
        guard next.setProfile(profile,scope:scope,context:currentContext) else { return false }
        guard commit(next) else { return false }
        error=nil;cancelDrag(); status = "Saved \(grid.preset.rawValue) grid for \(name). Existing windows stay where they are until placed."
        return true
    }
    func activate(scope: String, name: String, restore: Bool = true) {
        if detectingScene {
            var next=file;if next.profiles[scope]==nil { next.profiles[scope]=DesktopProfile(name:name) }
            next.activeScope=scope;_=commit(next);return
        }
        var next = file
        var profile=currentProfile(scope:scope); profile.name=name
        guard next.setProfile(profile,scope:scope,context:currentContext) else { return }
        next.activeScope = scope
        guard commit(next) else { return }
        cancelDrag(); refreshMonitoring()
        if restore { restoreSavedWindows() }
        else { status = "Using \(name)’s desktop grid" }
    }
    func screensChanged(snapshot:[DisplayConfiguration]?=nil) {
        let updated=Display.all
        let next=(snapshot ?? updated.map(DisplayConfiguration.init)).sorted { $0.id<$1.id }
        guard next != displayConfiguration else {
            onDiagnosticEvent?("unchanged display notification; kept current drag")
            return
        }
        let sameDisplays = next.count == displayConfiguration.count && zip(next, displayConfiguration).allSatisfy {
            $0.0.hasSameDisplay(as: $0.1)
        }
        displayConfiguration = next
        if sameDisplays {
            onDiagnosticEvent?("work area changed; kept current drag")
            displays = updated
            refreshOverlays()
            return
        }
        onDiagnosticEvent?("display topology changed; cancelling pending drag")
        cancelDrag();sceneTask?.cancel();displays=updated;detectingScene=true
        panels.values.forEach { $0.orderOut(nil) };panels.removeAll()
        status="Detecting display setup…"
        sceneTask=Task { [weak self] in
            do { try await Task.sleep(nanoseconds:600_000_000) } catch { return }
            guard let self,!Task.isCancelled else { return }
            self.displays=Display.all
            self.displayConfiguration=self.displays.map(DisplayConfiguration.init).sorted { $0.id<$1.id }
            self.detectingScene=false
            self.refreshSceneDetection(restore:true)
        }
    }
    func refreshMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if started && enabled && WindowManager.allowed && readable {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
            if monitor == nil { error = "Could not observe window drags. Restart Mischief Managed." }
        }
        refreshOverlays()
    }
    private func cancelDrag() {
        generation += 1; drag = nil; lastDragUpdate = 0; refreshOverlays()
    }
    private func handle(_ event: NSEvent) {
        onDiagnosticEvent?("event \(event.type.rawValue); detecting=\(detectingScene); enabled=\(enabled)")
        guard enabled, !detectingScene, WindowManager.allowed else { cancelDrag(); return }
        let point = event.cgEvent?.unflippedLocation ?? NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            cancelDrag()
            let hit=window(at:point)
            onDiagnosticEvent?("mouse down window hit=\(hit != nil)")
            guard let window = hit, point.y > window.frame.maxY-64,
                  point.y < window.frame.maxY-3, point.x > window.frame.minX+5, point.x < window.frame.maxX-5 else { return }
            drag = Drag(window: window, origin: window.frame)
        case .leftMouseDragged:
            guard var current = drag else { return }
            // AX work is bounded to at most 30 Hz while dragging, with no idle timer.
            guard event.timestamp-lastDragUpdate >= 1/30 else { return }; lastDragUpdate = event.timestamp
            guard let frame = WindowManager.frame(current.window.element) else { cancelDrag(); return }
            guard abs(frame.width-current.origin.width) < 3 && abs(frame.height-current.origin.height) < 3 else { cancelDrag(); return }
            current.moved = current.moved || hypot(frame.minX-current.origin.minX, frame.minY-current.origin.minY) > 4
            drag = current
            updateDragFeedback(point: point, flags: event.modifierFlags)
        case .flagsChanged:
            if drag != nil { updateDragFeedback(point: NSEvent.mouseLocation, flags: event.modifierFlags) }
        case .leftMouseUp:
            guard let current = drag else { onDiagnosticEvent?("drop without a tracked window drag"); return }
            let destination = target(at: point)
            let bypass = event.modifierFlags.contains(.option) || (requireShift && !event.modifierFlags.contains(.shift))
            let token = generation; drag = nil; refreshOverlays()
            onDiagnosticEvent?("drop tile=\(String(describing: destination?.index)); moved=\(current.moved); bypass=\(bypass)")
            guard !bypass, let destination else { return }
            // Global events are copies. Let the target application finish its mouse-up first.
            DispatchQueue.main.asyncAfter(deadline: .now()+0.12) { [weak self] in
                guard let self, token == self.generation, self.enabled, WindowManager.allowed else { return }
                if !current.moved {
                    guard let frame = WindowManager.frame(current.window.element),
                          abs(frame.width-current.origin.width) < 3, abs(frame.height-current.origin.height) < 3,
                          hypot(frame.minX-current.origin.minX, frame.minY-current.origin.minY) > 4 else { return }
                }
                guard let display = self.displays.first(where: { $0.id == destination.display.id }) else { return }
                let frames = self.grid(display: display.id).frames(in: display.visible)
                guard frames.indices.contains(destination.index) else { return }
                self.snap(current.window, to: frames[destination.index], display: display, previous: current.window)
            }
        default: break
        }
    }
    private func updateDragFeedback(point: CGPoint, flags: NSEvent.ModifierFlags) {
        let eligible = drag?.moved == true && !flags.contains(.option) && (!requireShift || flags.contains(.shift))
        let target = eligible ? target(at: point) : nil
        refreshOverlays(dragTarget: target.map { ($0.display.id, $0.index) })
        if let target { onDragHighlight?(target.display.id, target.index) }
    }
    private func target(at point: CGPoint) -> (display: Display, index: Int)? {
        guard let display = displays.first(where: { $0.visible.contains(point) }) else { return nil }
        let config = grid(display: display.id)
        guard let index = config.zone(at: point, in: display.visible) else { return nil }
        return (display, index)
    }
    private func window(at point: CGPoint) -> LiveWindow? {
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.25)
        var element: AXUIElement?
        let hitResult=AXUIElementCopyElementAtPosition(system, Float(point.x), Float(Display.primaryTop-point.y), &element)
        guard hitResult == .success, let hit = element else { onDiagnosticEvent?("AX hit error \(hitResult.rawValue)");return nil }
        let role=WindowManager.value(hit,kAXRoleAttribute) as? String ?? "unknown"
        var hitPID:pid_t=0;AXUIElementGetPid(hit,&hitPID)
        onDiagnosticEvent?("AX hit role=\(role); bundle=\(NSRunningApplication(processIdentifier:hitPID)?.bundleIdentifier ?? "unknown"); point=\(point)")
        let window: AXUIElement
        if (WindowManager.value(hit, kAXRoleAttribute) as? String) == kAXWindowRole { window = hit }
        else if let raw = WindowManager.value(hit, kAXWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() { window = raw as! AXUIElement }
        else { onDiagnosticEvent?("AX hit has no window");return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier,
              let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              (!ProcessInfo.processInfo.arguments.contains("--tiling-check") && !ProcessInfo.processInfo.arguments.contains("--fixture-windows-only")) || bundle == "com.pkhodo.FrameDeskTestCards",
              let live = try? WindowManager.scan(bundleIDs: [bundle]) else { return nil }
        return live.first { CFEqual($0.element, window) }
    }
    func placeFrontmost(in zone: Int, displayID: String) {
        guard !detectingScene else { return }
        guard WindowManager.allowed else { error = WindowError.permission.localizedDescription; return }
        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalPID : front?.processIdentifier
        guard let pid, let app = NSRunningApplication(processIdentifier: pid),
              let bundle = app.bundleIdentifier, let display = displays.first(where: { $0.id == displayID }) else { error = "Focus an app window first, then choose a zone."; return }
        let axApp = AXUIElementCreateApplication(pid)
        guard let raw = WindowManager.value(axApp, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID(),
              let live = try? WindowManager.scan(bundleIDs: [bundle]),
              let window = live.first(where: { CFEqual($0.element, raw) }) else { error = "No standard visible window is focused in \(app.localizedName ?? "that app")."; return }
        let frames = grid(display: displayID).frames(in: display.visible)
        guard frames.indices.contains(zone) else { return }
        snap(window, to: frames[zone], display: display, previous: window)
    }
    private func snap(_ window: LiveWindow, to target: CGRect, display: Display, previous: LiveWindow) {
        // Revalidate exact AX identity immediately before a move; never title-match a drag.
        guard let live = try? WindowManager.scan(bundleIDs: [window.placement.bundleID]),
              live.contains(where: { CFEqual($0.element, window.element) }),
              !detectingScene, commit(file) else { onDiagnosticEvent?("snap could not revalidate the window"); return }
        onDiagnosticEvent?("snap target: \(target)")
        generation += 1
        let token = generation
        let scope = file.activeScope
        let context = currentContext
        _ = WindowManager.move(window, to: target)

        // Position and size can change for several frames after a single AX write.
        // Wait for the frame to hold before correcting or saving it.
        Task { [weak self] in
            let start = ContinuousClock.now
            var settlement = TileSnapSettlement(target: target)
            while let self, self.canFinishSnap(token, scope: scope, context: context) {
                let actual = WindowManager.frame(window.element)
                let elapsed = start.duration(to: .now)
                self.onDiagnosticEvent?("snap at \(elapsed): \(String(describing: actual))")
                switch settlement.observe(actual, elapsed: elapsed) {
                case .wait:
                    break
                case .correct(let position, let size):
                    if size {
                        self.onDiagnosticEvent?("snap size does not match after settling; retrying resize")
                        // Preserve the initial size-position-size sequence. Some
                        // windows accept a size change only with a position write.
                        _ = WindowManager.move(window, to: target)
                    } else if position {
                        self.onDiagnosticEvent?("snap position does not match after resize; correcting position")
                        WindowManager.reposition(window, atTopLeftOf: target)
                    }
                case .finish:
                    if let actual {
                        self.finishSnap(window, to: target, actual: actual, displayID: display.id, previous: previous, live: live)
                    }
                    return
                case .unsettled:
                    self.undo = Undo(scope: scope, profile: self.currentProfile(), windows: [previous], displays: self.displaySnapshot, context: context)
                    self.canUndo = true
                    self.status = "Couldn’t confirm where \(window.placement.appName) settled. Its saved position is unchanged. Undo is available."
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
    private func canFinishSnap(_ token: Int, scope: String, context: SceneContext) -> Bool {
        token == generation && !detectingScene && file.activeScope == scope && currentContext == context
            && WindowManager.allowed && NSEvent.pressedMouseButtons == 0
    }
    private func atTileOrigin(_ frame: CGRect, _ tile: CGRect) -> Bool {
        abs(frame.minX - tile.minX) < 5 && abs(frame.maxY - tile.maxY) < 5
    }
    private func finishSnap(_ window: LiveWindow, to target: CGRect, actual: CGRect, displayID: String,
                            previous: LiveWindow, live: [LiveWindow]) {
        guard let display = displays.first(where: { $0.id == displayID }) else { return }
        let profile = currentProfile()
        let positioned = atTileOrigin(actual, target)
        let exact = TileSnapSettlement.fillsTile(actual, target)
        onDiagnosticEvent?("snap final: \(actual); fits=\(exact)")
        let operationUndo = Undo(scope: file.activeScope, profile: profile, windows: [previous], displays: displaySnapshot, context: currentContext)
        guard positioned else {
            undo = operationUndo
            canUndo = true
            status = "Couldn’t move \(window.placement.appName) to the tile. Its saved position is unchanged. Undo is available."
            return
        }
        var next = file
        var placement = window.placement
        var bindings = liveAssignments[bindingKey, default: []].filter { binding in
            profile.windows.contains { $0.id == binding.placementID } && live.contains { CFEqual($0.element, binding.element) }
        }
        if let binding = bindings.first(where: { CFEqual($0.element, window.element) }) {
            placement.id = binding.placementID
        } else if let match = WindowMatching.match(saved: profile.windows, live: live.map(\.placement)).first(where: { CFEqual(live[$0.live].element, window.element) }) {
            placement.id = profile.windows[match.saved].id
        }
        placement.displayID = displayKey(display.id); placement.normalized = Geometry.normalized(actual, in: display.visible)
        // Constrained windows must remain within the connected display to be persistent.
        let safe = display.visible.insetBy(dx: -1, dy: -1).contains(actual)
        if safe {
            var updated=profile
            updated.windows.removeAll { $0.id == placement.id };updated.windows.append(placement)
            guard next.setProfile(updated,scope:file.activeScope,context:currentContext) else { return }
        }
        guard commit(next) else { _ = WindowManager.move(previous, to: previous.frame); return }
        if safe {
            bindings.removeAll { CFEqual($0.element, window.element) || $0.placementID == placement.id }
            bindings.append((window.element, placement.id)); liveAssignments[bindingKey] = bindings
        }
        undo = operationUndo
        canUndo = true
        status = exact ? "Snapped \(placement.appName) — position saved for \(activeName)" : "\(placement.appName) didn’t fill the tile. \(safe ? "Actual position saved." : "Position could not be saved inside this display.") Undo is available."
    }
    func restoreSavedWindows(connectedDisplays: [Display]? = nil) {
        guard !detectingScene, WindowManager.allowed else { return }
        if hasDisplayScenes && currentContext == .unassigned { status="Unrecognized setup — saved scene windows were not moved.";return }
        let profile=currentProfile()
        guard !profile.windows.isEmpty else { return }
        cancelDrag()
        let connected = connectedDisplays ?? displays
        do {
            let live = try WindowManager.scan(bundleIDs: Set(profile.windows.map(\.bundleID)))
            let matches = resolvedMatches(saved: profile.windows, live: live)
            let applicable = matches.filter { match in connected.contains(where: { displayKey($0.id) == profile.windows[match.saved].displayID }) }
            var restored = 0
            for match in applicable {
                let placement = profile.windows[match.saved]
                guard let display = connected.first(where: { displayKey($0.id) == placement.displayID }) else { continue }
                let target = Geometry.expanded(placement.normalized, in: display.visible)
                if WindowManager.move(live[match.live], to: target) { restored += 1 }
            }
            if !applicable.isEmpty { undo = Undo(scope: file.activeScope, profile: profile, windows: applicable.map { live[$0.live] }, displays: displaySnapshot, context: currentContext); canUndo = true }
            liveAssignments[bindingKey] = matches.map { (live[$0.live].element, profile.windows[$0.saved].id) }
            status = "Restored \(restored) of \(profile.windows.count) saved tiled windows. Missing displays and ambiguous windows are skipped."
        } catch { self.error = error.localizedDescription }
    }
    func undoLastMove() {
        guard let undo,!detectingScene,undo.context==currentContext else { return }
        cancelDrag()
        var next = file
        var profile=currentProfile(scope:undo.scope);profile.windows=undo.profile.windows
        guard next.setProfile(profile,scope:undo.scope,context:undo.context) else { return }
        guard commit(next) else { return }
        let live = (try? WindowManager.scan(bundleIDs: Set(undo.windows.map { $0.placement.bundleID }))) ?? []
        var restored = 0; var adjusted = 0
        for old in undo.windows {
            guard live.contains(where: { CFEqual($0.element, old.element) }),
                  let display = displays.first(where: { $0.id == old.placement.displayID }) else { continue }
            let target = DesktopUndoGeometry.target(original: old.frame, originalDisplays: undo.displays, currentDisplays: displaySnapshot, bounds: display.visible)
            if target != old.frame { adjusted += 1 }
            if WindowManager.move(old, to: target) { restored += 1 }
        }
        status = "Undid tiling for \(restored) of \(undo.windows.count) windows" + (adjusted > 0 ? " · \(adjusted) adjusted to the changed display arrangement" : "")
        self.undo = nil; canUndo = false
    }
    private func resolvedMatches(saved: [Placement], live: [LiveWindow]) -> [(saved: Int, live: Int)] {
        var result: [(saved: Int, live: Int)] = []
        for (i, placement) in saved.enumerated() {
            guard let binding = liveAssignments[bindingKey]?.first(where: { $0.placementID == placement.id }),
                  let j = live.firstIndex(where: { CFEqual($0.element, binding.element) }),
                  !result.contains(where: { $0.live == j }) else { continue }
            result.append((i, j))
        }
        let remainingSaved = saved.indices.filter { index in !result.contains { $0.saved == index } }
        let remainingLive = live.indices.filter { index in !result.contains { $0.live == index } }
        for match in WindowMatching.match(saved: remainingSaved.map { saved[$0] }, live: remainingLive.map { live[$0].placement }) {
            result.append((remainingSaved[match.saved], remainingLive[match.live]))
        }
        return result
    }
    private func refreshOverlays(dragTarget: (String, Int)? = nil) {
        guard started,!detectingScene else { panels.values.forEach { $0.orderOut(nil) }; return }
        let visible = file.showGrid || dragTarget != nil
        for display in displays {
            guard visible else { panels[display.id]?.orderOut(nil); continue }
            let panel = panels[display.id] ?? GridPanel()
            panels[display.id] = panel
            let config = grid(display: display.id)
            panel.setFrame(display.visible, display: false)
            panel.gridView.frames = config.frames(in: display.visible).map {
                $0.offsetBy(dx: -display.visible.minX, dy: -display.visible.minY)
            }
            panel.gridView.isDraggingWindow = dragTarget != nil
            panel.gridView.highlight = dragTarget?.0 == display.id ? dragTarget?.1 : nil
            panel.gridView.needsDisplay = true
            panel.orderFrontRegardless()
        }
    }
}

final class GridPanel: NSPanel {
    let gridView = DesktopGridView()
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; ignoresMouseEvents = true
        level = .floating; collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        hidesOnDeactivate = false; isReleasedWhenClosed = false
        contentView = gridView
        setAccessibilityElement(false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DesktopGridView: NSView {
    var frames: [CGRect] = []
    var highlight: Int?
    var isDraggingWindow = false
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        if !isDraggingWindow {
            let path = NSBezierPath()
            for rect in frames { path.appendRect(rect.insetBy(dx: 0.5, dy: 0.5)) }
            let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            NSColor.black.withAlphaComponent(highContrast ? 0.72 : 0.28).setStroke()
            path.lineWidth = 2
            path.stroke()
            NSColor.white.withAlphaComponent(highContrast ? 0.82 : 0.38).setStroke()
            path.lineWidth = 1
            path.stroke()
            return
        }
        for (i, frame) in frames.enumerated() {
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
            if highlight == i { NSColor.controlAccentColor.withAlphaComponent(0.18).setFill(); path.fill() }
            NSColor.black.withAlphaComponent(0.8).setStroke(); path.lineWidth = 3; path.stroke()
            (highlight == i ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.9)).setStroke()
            path.lineWidth = highlight == i ? 2.5 : 1; path.stroke()
            let label = "\(i+1)" as NSString
            let rect = CGRect(x: frame.midX-15, y: frame.maxY-38, width: 30, height: 26)
            NSColor.black.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: rect.midX-size.width/2, y: rect.midY-size.height/2), withAttributes: attrs)
        }
    }
}
