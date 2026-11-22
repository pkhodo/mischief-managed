import AppKit
import ApplicationServices
import SwiftUI
import FrameDeskCore

@MainActor
final class AppState: ObservableObject {
    @Published var displays = Display.all
    @Published var displayID = ""
    @Published var region = CGRect.zero
    @Published var editing = false
    @Published var capturing = false
    @Published var busy = false
    @Published private(set) var restarting = false
    @Published var status = "Ready"
    @Published var error: String?
    @Published var accessibilityAllowed = WindowManager.allowed
    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published var layouts: [Workspace] = []
    @Published var layoutName = ""
    @Published var pickerWindows: [LiveWindow] = []
    @Published var selectedWindows: Set<UUID> = []
    @Published var showWindowPicker = false
    @Published var canUndo = false
    let capture = CaptureController()
    let overlay = RegionOverlay()
    let tiling: DesktopTilingManager
    private let store: WorkspaceStore
    private var file = WorkspaceFile()
    private var storageReadable = true
    private var undo: [LiveWindow] = []
    private var captureGeneration: UInt64 = 0
    private var displayObserver: NSObjectProtocol?

    var display: Display? { displays.first(where: { $0.id == displayID }) ?? displays.first }
    var area: SavedArea? { display.map { SavedArea(displayID: $0.id, normalized: Geometry.normalized(region, in: $0.frame)) } }
    var outputLabel: String {
        guard let display else { return "No display" }
        let size = Geometry.outputSize(region: region.size, scale: display.screen.backingScaleFactor)
        return "\(Int(region.width)) × \(Int(region.height)) pt · up to \(Int(size.width)) × \(Int(size.height)) px"
    }
    init(directory: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["FRAMEDESK_DATA_DIR"]
        let directory = directory ?? override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FrameDesk", isDirectory: true)
        tiling = DesktopTilingManager(directory: directory)
        store = WorkspaceStore(url: directory.appendingPathComponent("workspaces.json"))
        do { file = try store.load(); layouts = file.layouts }
        catch { self.error = "Could not read saved layouts: \(error.localizedDescription) Your file has not been changed. Location: \(store.url.path)"; storageReadable = false }
        displayID = displays.first?.id ?? ""
        if let saved = file.area, let d = displays.first(where: { $0.id == saved.displayID }) {
            displayID = d.id; region = Geometry.clamped(Geometry.expanded(saved.normalized, in: d.frame), in: d.visible)
        } else { resetArea(corner: 1, persist: false) }
        overlay.view.onMove = { [weak self] frame in self?.region = frame }
        overlay.view.onCommit = { [weak self] _ in self?.persist() }
        overlay.view.onFinish = { [weak self] in self?.toggleEditing() }
        capture.onFirstFrame = { [weak self] in self?.status = "Preview live — share the Mischief Managed preview window" }
        capture.onStatus = { [weak self] text in self?.status = text }
        capture.onFailure = { [weak self] text in
            self?.capturing = false; self?.busy = false
            self?.status = "Capture stopped"; self?.error = "Screen capture stopped: \(text)"
            self?.refreshOverlay()
        }
        capture.onClose = { [weak self] in self?.stopCapture() }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displaysChanged() }
        }
    }
    func refreshPermissions() {
        accessibilityAllowed = WindowManager.allowed
        screenAllowed = CGPreflightScreenCaptureAccess()
    }
    func openPermission(_ kind: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(kind)"),
              NSWorkspace.shared.open(url) else {
            error = "Could not open System Settings. Open it from the Apple menu, then choose Privacy & Security → \(kind == "ScreenCapture" ? "Screen & System Audio Recording" : kind)."
            return
        }
    }
    func requestPermission(_ kind: String) {
        switch kind {
        case "Accessibility":
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case "ScreenCapture":
            _ = CGRequestScreenCaptureAccess()
        default: return
        }
        refreshPermissions()
    }
    func restartForPermissions(activityManager: ActivityManager, launch: ((@escaping (Error?) -> Void) -> Void)? = nil) {
        guard !capturing && !busy && !activityManager.busy && !restarting else { return }
        restarting = true
        let completed: (Error?) -> Void = { failure in
            Task { @MainActor in
                if let failure {
                    self.restarting = false
                    self.error = "Could not restart Mischief Managed: \(failure.localizedDescription) Quit and reopen it manually."
                }
                else { NSApplication.shared.terminate(nil) }
            }
        }
        if let launch { launch(completed) }
        else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, failure in completed(failure) }
        }
    }
    @discardableResult
    func persist() -> Bool {
        guard storageReadable else {
            error = "The existing layout file could not be read. It has not been overwritten. Check \(store.url.path) and reopen Mischief Managed."
            return false
        }
        var next = file; next.area = area; next.layouts = layouts
        do { try store.save(next); file = next; return true }
        catch { self.error = "Could not save layouts: \(error.localizedDescription) Changes remain in memory; the previous file is intact."; return false }
    }
    func resetArea(corner: Int, persist shouldPersist: Bool = true) {
        guard let display else { return }
        let width = min(display.frame.width / 2, display.visible.height * 16 / 9)
        let height = width * 9 / 16
        let x = corner % 2 == 0 ? display.visible.minX : display.visible.maxX-width
        let y = corner < 2 ? display.visible.maxY-height : display.visible.minY
        setRegion(CGRect(x: x, y: y, width: width, height: height), persist: shouldPersist)
    }
    func setRegion(_ next: CGRect, persist shouldPersist: Bool = true) {
        guard let display else { return }
        region = Geometry.clamped(next, in: display.visible, minimum: CGSize(width: 240, height: 135))
        if shouldPersist { persist() }
        refreshOverlay()
        if capturing && !editing { restartCapture() }
    }
    func chooseDisplay(_ id: String) {
        guard id != displayID else { return }
        if capturing { stopCapture() }
        displayID = id; resetArea(corner: 1)
    }
    func refreshOverlay() {
        guard let display else { overlay.hide(); return }
        if editing || capturing { overlay.show(frame: region, editable: editing, bounds: display.visible) }
        else { overlay.hide() }
    }
    func toggleEditing() {
        guard !busy else { return }
        editing.toggle()
        if editing && capturing { capture.pauseForEditing(); status = "Adjusting area — preview paused" }
        if !editing { persist(); if capturing { restartCapture() } }
        refreshOverlay()
    }
    func startCapture() {
        guard !busy, let display else { return }
        if editing { editing = false; persist() }
        busy = true; error = nil
        captureGeneration &+= 1
        let generation = captureGeneration
        let requestedRegion = region
        Task {
            guard generation == captureGeneration else { return }
            defer { if generation == captureGeneration { busy = false; refreshPermissions(); refreshOverlay() } }
            do {
                try await capture.start(display: display, region: requestedRegion)
                guard generation == captureGeneration else { return }
                capturing = true
            }
            catch is CancellationError { if generation == captureGeneration { capturing = false } }
            catch {
                guard generation == captureGeneration else { return }
                capturing = false; status = "Capture could not start"
                self.error = "\(error.localizedDescription) If Screen Recording is not allowed, enable Mischief Managed there and reopen the app."
            }
        }
    }
    private func restartCapture() {
        guard !busy, let display else { return }
        busy = true
        captureGeneration &+= 1
        let generation = captureGeneration
        let requestedRegion = region
        Task {
            guard generation == captureGeneration else { return }
            defer { if generation == captureGeneration { busy = false; refreshOverlay() } }
            do {
                try await capture.reframe(display: display, region: requestedRegion)
                guard generation == captureGeneration else { return }
            }
            catch is CancellationError { if generation == captureGeneration { capturing = false } }
            catch {
                guard generation == captureGeneration else { return }
                capturing = false; status = "Capture stopped"; self.error = error.localizedDescription
            }
        }
    }
    func stopCapture() {
        captureGeneration &+= 1
        capturing = false; busy = false; status = "Capture paused"
        capture.stop()
        refreshOverlay()
    }
    func saveLayout() {
        guard storageReadable else { persist(); return }
        do {
            let windows = try WindowManager.scan()
            guard !windows.isEmpty else { throw WindowError.noWindows }
            let name = layoutName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            layouts.append(Workspace(name: name, windows: windows.map(\.placement), area: area))
            layoutName = ""; let saved = persist()
            status = saved ? "Saved \(windows.count) windows" : "Layout not saved to disk"
        } catch { self.error = error.localizedDescription }
    }
    func restore(_ workspace: Workspace) {
        guard !busy else { return }
        do {
            let live = try WindowManager.scan(bundleIDs: Set(workspace.windows.map(\.bundleID)))
            let matched = WindowMatching.match(saved: workspace.windows, live: live.map(\.placement))
            undo = matched.map { live[$0.live] }; canUndo = !undo.isEmpty
            apply(workspace.windows, to: live)
            if let saved = workspace.area {
                if let target = displays.first(where: { $0.id == saved.displayID }) { displayID = target.id }
                if let display { setRegion(Geometry.expanded(saved.normalized, in: display.frame)) }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func apply(_ placements: [Placement], to live: [LiveWindow]) {
        let matches = WindowMatching.match(saved: placements, live: live.map(\.placement))
        var moved = 0; var constrained = 0
        for match in matches {
            let saved = placements[match.saved]
            guard let target = displays.first(where: { $0.id == saved.displayID }) ?? display else { continue }
            let frame = Geometry.clamped(Geometry.expanded(saved.normalized, in: target.visible), in: target.visible)
            if WindowManager.move(live[match.live], to: frame) { moved += 1 } else { constrained += 1 }
        }
        let missing = placements.count-matches.count
        status = "Restored \(moved) windows" + (constrained > 0 ? " · \(constrained) constrained by their app" : "") + (missing > 0 ? " · \(missing) unavailable or ambiguous" : "")
    }
    func restorePrevious() {
        guard canUndo else { return }
        do {
            let live = try WindowManager.scan(bundleIDs: Set(undo.map { $0.placement.bundleID }))
            var moved = 0
            for old in undo {
                guard let current = live.first(where: { CFEqual($0.element, old.element) }),
                      let target = displays.first(where: { $0.id == old.placement.displayID }) ?? display else { continue }
                let frame = Geometry.clamped(Geometry.expanded(old.placement.normalized, in: target.visible), in: target.visible)
                if WindowManager.move(current, to: frame) { moved += 1 }
            }
            status = "Restored \(moved) of \(undo.count) previous window positions"
            undo = []; canUndo = false
        }
        catch { self.error = error.localizedDescription }
    }
    func deleteLayout(_ layout: Workspace) {
        layouts.removeAll { $0.id == layout.id }; persist()
    }
    func openTilePicker() {
        do { pickerWindows = try WindowManager.scan(); selectedWindows = []; showWindowPicker = true }
        catch { self.error = error.localizedDescription }
    }
    func tileSelected() {
        do {
            // Rescan at commit so closed or replaced windows are never moved through stale handles.
            let chosen = pickerWindows.filter { selectedWindows.contains($0.id) }
            let current = try WindowManager.scan(bundleIDs: Set(chosen.map { $0.placement.bundleID }))
            // A live AX element identifies the exact selected window, including duplicate titles.
            let matches = chosen.compactMap { selected in current.firstIndex { CFEqual($0.element, selected.element) } }
            undo = matches.map { current[$0] }; canUndo = !undo.isEmpty
            let boxes = Geometry.tiles(count: matches.count, in: region)
            var moved = 0
            for (i, match) in matches.enumerated() { if WindowManager.move(current[match], to: boxes[i]) { moved += 1 } }
            status = "Tiled \(moved) of \(chosen.count) windows; some apps enforce minimum sizes"
            showWindowPicker = false
        } catch { self.error = error.localizedDescription }
    }
    private func displaysChanged() {
        stopCapture(); editing = false; overlay.hide(); displays = Display.all
        if !displays.contains(where: { $0.id == displayID }) { displayID = displays.first?.id ?? "" }
        if let display { region = Geometry.clamped(region, in: display.visible) }
        status = "Display configuration changed — check the area before restarting capture"
    }
}
