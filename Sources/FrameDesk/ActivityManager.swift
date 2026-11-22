import AppKit
import FrameDeskCore

@MainActor
final class ActivityManager: ObservableObject {
    @Published private(set) var file = ActivityFile()
    @Published var selectedID: UUID?
    @Published var busy = false
    @Published var message = ""
    @Published var error: String?
    private let store: ActivityStore
    private var readable = true
    let browser: any ActivityBrowser
    var activities: [Activity] { file.activities }

    init(directory: URL? = nil, browser: any ActivityBrowser = EdgeBrowser()) {
        self.browser = browser
        let override = ProcessInfo.processInfo.environment["FRAMEDESK_DATA_DIR"]
        let base = directory ?? override.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FrameDesk")
        store = ActivityStore(url: base.appendingPathComponent("activities.json"))
        do {
            if FileManager.default.fileExists(atPath: store.url.path) { file = try store.load() }
            else {
                let legacy = try WorkspaceStore(url: base.appendingPathComponent("workspaces.json")).load()
                file = try store.load(legacy: legacy.layouts)
                if !file.activities.isEmpty { try store.save(file) }
            }
            selectedID = file.activities.first?.id
        } catch { readable = false; self.error = "Could not load activities. \(error.localizedDescription) File: \(store.url.path)" }
    }

    @discardableResult
    private func commit(_ next: ActivityFile) -> Bool {
        guard readable else { error = "The existing activities file could not be read. It has not been changed. Reopen Mischief Managed after checking \(store.url.path)."; return false }
        do { try store.save(next); file = next; return true }
        catch { self.error = "Could not save activities: \(error.localizedDescription) Nothing will be closed."; return false }
    }
    func save(_ activity: Activity) -> Bool {
        var a = activity; a.name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.name.isEmpty else { error = "Give this activity a name."; return false }
        if session(a.id) != nil, let old = activities.first(where: { $0.id == a.id }), old.websites != a.websites {
            error = "Save & close the website window before editing its saved website list."; return false
        }
        guard !activities.contains(where: { $0.id != a.id && $0.name.caseInsensitiveCompare(a.name) == .orderedSame }) else {
            error = "An activity already uses that name. Choose another name."; return false
        }
        var next = file
        if let i = next.activities.firstIndex(where: { $0.id == a.id }) { next.activities[i] = a }
        else { next.activities.append(a) }
        guard commit(next) else { return false }
        selectedID = a.id
        message = session(a.id) == nil ? "Saved \(a.name)" : "Saved \(a.name). Its open website window is unchanged."
        return true
    }
    func setFavorite(_ id: UUID, _ value: Bool) {
        guard var a = activities.first(where: { $0.id == id }) else { return }
        a.favorite = value; _ = save(a)
    }
    func setKeepOpen(_ id: UUID, _ value: Bool) {
        guard var a = activities.first(where: { $0.id == id }) else { return }
        a.keepOpen = value; _ = save(a)
    }
    func delete(_ id: UUID) {
        guard session(id) == nil else { error = "Save & close this activity’s website window before deleting its setup."; return }
        var next = file; next.activities.removeAll { $0.id == id }
        if commit(next), selectedID == id { selectedID = activities.first?.id }
    }
    func session(_ id: UUID) -> ActivityBrowserSession? { file.sessions.first { $0.activityID == id } }
    func forget(_ id: UUID) {
        var next = file; next.sessions.removeAll { $0.activityID == id }; _ = commit(next)
    }
    func refreshBrowserLaunch() {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: EdgeBrowser.bundleID).first
        let valid = file.sessions.filter { s in
            guard let app, let date = app.launchDate else { return false }
            return s.belongs(to: app.processIdentifier, launchedAt: date)
        }
        if valid != file.sessions { var next = file; next.sessions = valid; _ = commit(next) }
    }
    func open(_ id: UUID, state: AppState? = nil) async {
        guard !busy, let activity = activities.first(where: { $0.id == id }) else { return }
        busy = true; error = nil; defer { busy = false }
        guard commit(file) else { return } // prove persistence before creating owned resources
        do {
            var alreadyOpen = false
            if let existing = session(id) {
                // Focusing an owned window does not require every current tab to
                // be a serializable website (for example an Edge New Tab).
                do { try await browser.focus(existing); alreadyOpen = true }
                catch BrowserError.expired { forget(id); guard session(id) == nil else { return } }
                catch BrowserError.missing { forget(id); guard session(id) == nil else { return } }
            }
            var unavailable: [String] = []
            var launched: Set<String> = []
            let savedWindows = state?.tiling.savedWindows(for: activity) ?? activity.windows
            let appWindows = state?.tiling.hasDisplayScenes == true && state?.tiling.currentContext == .unassigned
                ? activity.windows : savedWindows
            for bundle in Set(appWindows.map(\.bundleID)) {
                if bundle == EdgeBrowser.bundleID && !activity.websites.isEmpty { continue }
                if !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty { continue }
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { unavailable.append(bundle); continue }
                let config = NSWorkspace.OpenConfiguration(); config.activates = false
                do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config); launched.insert(bundle) }
                catch { unavailable.append(bundle) }
            }
            if !savedWindows.isEmpty, let state {
                state.refreshPermissions()
                if state.accessibilityAllowed {
                    if !launched.isEmpty {
                        for _ in 0..<20 {
                            let present = Set((try? WindowManager.scan(bundleIDs: launched))?.map { $0.placement.bundleID } ?? [])
                            if launched.isSubset(of: present) { break }
                            try await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }
                    if state.tiling.usesOriginalArrangement(for: activity), !activity.windows.isEmpty {
                        state.restore(activity.workspace)
                        if let message = state.error { unavailable.append(message) }
                    }
                }
                else { unavailable.append("window layout (Accessibility is not allowed)") }
            }
            if let saved = activity.area, let state {
                if let d = state.displays.first(where: { $0.id == saved.displayID }) { state.displayID = d.id }
                if let d = state.display { state.setRegion(Geometry.expanded(saved.normalized, in: d.frame)) }
            }
            if !alreadyOpen && !activity.websites.isEmpty {
                var bounds = state?.tiling.hasDisplayScenes == true ? state?.tiling.sceneBrowserBounds(scope:id.uuidString) : activity.browserBounds
                if state?.tiling.hasDisplayScenes != true, let b = bounds, let display = state?.display {
                    bounds = Box(Geometry.flipped(Geometry.clamped(Geometry.flipped(b.rect, primaryTop: Display.primaryTop), in: display.visible), primaryTop: Display.primaryTop))
                }
                let created = try await browser.open(activity: activity, bounds: bounds)
                // Retain ownership in memory even if the following disk write fails.
                file.sessions.removeAll { $0.activityID == id }; file.sessions.append(created)
                guard commit(file) else { return }
            }
            var next = file
            if let i = next.activities.firstIndex(where: { $0.id == id }) { next.activities[i].lastOpened = Date() }
            guard commit(next) else { return }
            selectedID = id
            state?.tiling.activate(scope: id.uuidString, name: activity.name)
            message = alreadyOpen ? "Returned to \(activity.name) — no duplicate website window" : "Opened \(activity.name)"
            if !savedWindows.isEmpty, let state {
                message += " · \(state.tiling.usesOriginalArrangement(for: activity) ? state.status : state.tiling.status)"
            }
            if !unavailable.isEmpty { error = "Some items could not open: \(unavailable.joined(separator: ", ")). Closed documents are not recreated." }
        } catch { self.error = error.localizedDescription }
    }
    func saveAndCloseWebsites(_ id: UUID) async {
        guard !busy, let a = activities.first(where: { $0.id == id }), let owned = session(id) else { return }
        guard !a.keepOpen else { error = "Turn off Keep open before closing this activity’s website window."; return }
        busy = true; error = nil; defer { busy = false }
        do {
            let snapshot = try await browser.snapshot(owned)
            var next = file
            guard let i = next.activities.firstIndex(where: { $0.id == id }) else { return }
            next.activities[i].websites = snapshot.websites
            next.activities[i].browserBounds = snapshot.bounds
            guard commit(next) else { return } // no close if recipe could not be saved
            if try await browser.close(owned) {
                forget(id)
                message = "Saved and closed \(a.name)’s website window. Other app windows stay open."
            } else { error = "Edge kept the window open. Finish or cancel its dialog, then try again. The activity is still tracked." }
        } catch BrowserError.missing { forget(id); message = "The website window was already closed. Its saved website list is unchanged." }
        catch BrowserError.expired { forget(id); error = "Edge restarted; its old window ID was discarded. No browser window was closed." }
        catch { self.error = error.localizedDescription }
    }
}
