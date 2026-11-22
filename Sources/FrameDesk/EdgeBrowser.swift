import AppKit
import FrameDeskCore

struct BrowserSnapshot: Sendable {
    var websites: [String]
    var bounds: Box
}

protocol ActivityBrowser: Sendable {
    func open(activity: Activity, bounds: Box?) async throws -> ActivityBrowserSession
    func snapshot(_ session: ActivityBrowserSession) async throws -> BrowserSnapshot
    func focus(_ session: ActivityBrowserSession) async throws
    func close(_ session: ActivityBrowserSession) async throws -> Bool
}

enum BrowserError: LocalizedError {
    case unavailable, permission, expired, missing, operation(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Microsoft Edge is not installed. Install it before opening this activity’s websites."
        case .permission: return "Allow Mischief Managed to control Microsoft Edge in System Settings → Privacy & Security → Automation, then try again."
        case .expired: return "Edge was restarted. Mischief Managed will not close a window using an old window ID. Open the activity again to create a new website window."
        case .missing: return "This activity’s website window is already closed."
        case .operation(let text): return "Edge could not finish: \(text)"
        }
    }
}

/// Uses Edge's documented-by-its-dictionary tab/window AppleEvents, never UI
/// scripting, private profile files, or whole-browser quit commands.
actor EdgeBrowser: ActivityBrowser {
    static let bundleID = "com.microsoft.edgemac"
    nonisolated static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    private func execute(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: "with timeout of 15 seconds\n" + source + "\nend timeout") else { throw BrowserError.operation("Could not prepare the browser request.") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -1743 { throw BrowserError.permission }
            if number == -1728 { throw BrowserError.missing }
            throw BrowserError.operation(error[NSAppleScript.errorMessage] as? String ?? "Error \(number)")
        }
        return result
    }
    private func identity() throws -> (Int32, Date) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first,
              let date = app.launchDate else { throw BrowserError.expired }
        return (app.processIdentifier, date)
    }
    private func verify(_ session: ActivityBrowserSession) throws {
        let (pid, date) = try identity()
        guard session.belongs(to: pid, launchedAt: date) else { throw BrowserError.expired }
    }
    func open(activity: Activity, bounds: Box?) async throws -> ActivityBrowserSession {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil else { throw BrowserError.unavailable }
        let sites = try activity.websites.map(WebsiteList.normalize)
        guard let first = sites.first else { throw BrowserError.operation("Add at least one website first.") }
        // A newly created browser window is the ownership boundary. Existing
        // browser windows are not adopted or closed as a side effect of opening.
        var script = "tell application id \"\(Self.bundleID)\"\nset w to make new window\ntry\nset URL of active tab of w to \(Self.quoted(first))\n"
        for site in sites.dropFirst() { script += "make new tab at end of tabs of w with properties {URL:\(Self.quoted(site))}\n" }
        if let b = bounds {
            script += "set bounds of w to {\(Int(b.x)), \(Int(b.y)), \(Int(b.x+b.width)), \(Int(b.y+b.height))}\n"
        }
        script += "set index of w to 1\nactivate\nreturn id of w\non error messageText number errorNumber\ntry\nclose w\nend try\nerror messageText number errorNumber\nend try\nend tell"
        let descriptor = try execute(script)
        let id = Int(descriptor.int32Value)
        guard id > 0 else { throw BrowserError.operation("Edge returned no new window ID.") }
        let (pid, date) = try identity()
        return ActivityBrowserSession(activityID: activity.id, windowID: id, processID: pid, launchedAt: date)
    }
    func snapshot(_ session: ActivityBrowserSession) throws -> BrowserSnapshot {
        try verify(session)
        let result = try execute("""
        tell application id "\(Self.bundleID)"
            set w to first window whose id is \(session.windowID)
            return {URL of every tab of w, bounds of w}
        end tell
        """)
        guard let tabs = result.atIndex(1), let rect = result.atIndex(2), rect.numberOfItems == 4 else {
            throw BrowserError.operation("Could not read the website window. It has been left open.")
        }
        let websites = try (1...max(1, tabs.numberOfItems)).map { index in
            try WebsiteList.normalize(tabs.atIndex(index)?.stringValue ?? "")
        }
        let b = (1...4).map { Int(rect.atIndex($0)?.int32Value ?? 0) }
        let bounds = Box(CGRect(x: b[0], y: b[1], width: b[2]-b[0], height: b[3]-b[1]))
        guard bounds.isValid else { throw BrowserError.operation("The browser window has invalid bounds.") }
        return BrowserSnapshot(websites: websites, bounds: bounds)
    }
    func focus(_ session: ActivityBrowserSession) throws {
        try verify(session)
        _ = try execute("tell application id \"\(Self.bundleID)\"\nset index of (first window whose id is \(session.windowID)) to 1\nactivate\nend tell")
    }
    func close(_ session: ActivityBrowserSession) async throws -> Bool {
        try verify(session)
        _ = try execute("tell application id \"\(Self.bundleID)\" to close (first window whose id is \(session.windowID))")
        for _ in 0..<15 {
            try verify(session)
            let result = try execute("tell application id \"\(Self.bundleID)\" to return exists (first window whose id is \(session.windowID))")
            if !result.booleanValue { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false // a browser save/before-unload dialog may have kept it open
    }
}
