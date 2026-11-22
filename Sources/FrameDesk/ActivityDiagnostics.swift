import AppKit
import FrameDeskCore
import Darwin

@MainActor
enum ActivityDiagnostics {
    static func runIfRequested(manager: ActivityManager, state: AppState) {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--tiling-check") { TilingDiagnostics.runIfRequested(state: state); return }
        if let flag = args.firstIndex(of: "--permissions-check"), args.indices.contains(flag+1) {
            NativeDiagnostics.permissions(report: URL(fileURLWithPath: args[flag+1])); return
        }
        if let flag = args.firstIndex(of: "--icon-evidence"), args.indices.contains(flag+1) {
            Task { await NativeDiagnostics.iconEvidence(directory: URL(fileURLWithPath: args[flag+1])) }; return
        }
        if let flag = args.firstIndex(of: "--activity-ui-snapshot") ?? args.firstIndex(of: "--permissions-ui-snapshot"), args.indices.contains(flag+1) {
            if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            else { NSApp.appearance = NSAppearance(named: .aqua) }
            let path = args[flag+1]
            DispatchQueue.main.asyncAfter(deadline: .now()+1) {
                guard let window = NSApp.windows.first(where: { $0.title == "Mischief Managed" }), let view = (window.attachedSheet ?? window).contentView else { NSApp.terminate(nil); return }
                if args.contains("--permissions-ui-snapshot") {
                    // A restored activity-window size must not pad the fixed-size
                    // Settings view with unrelated hosting-view margins.
                    window.contentMinSize = NSSize(width: 640, height: 780)
                    window.setContentSize(NSSize(width: 640, height: 780))
                }
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
                view.cacheDisplay(in: view.bounds, to: rep)
                // NSHostingView's cached bitmap omits the native window backing.
                // Draw that backing explicitly rather than delivering transparent
                // black-on-black text as if it were a real UI defect.
                let canvas = NSImage(size: view.bounds.size)
                canvas.lockFocus()
                (args.contains("--dark") ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor.windowBackgroundColor).setFill()
                NSBezierPath(rect: NSRect(origin: .zero, size: view.bounds.size)).fill()
                rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
                canvas.unlockFocus()
                if let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                // Test-only process with isolated data: an open editor sheet must
                // not defer termination and leave the rendering harness hanging.
                Darwin.exit(0)
            }
        }
        guard let flag = args.firstIndex(of: "--activity-check"), args.indices.contains(flag+1) else { return }
        let url = URL(fileURLWithPath: args[flag+1])
        guard let directory = ProcessInfo.processInfo.environment["FRAMEDESK_DATA_DIR"],
              URL(fileURLWithPath: directory).standardizedFileURL == url.deletingLastPathComponent().appendingPathComponent("app-data").standardizedFileURL else {
            let failure: [String: Any] = ["all_passed": false, "error": "The browser diagnostic requires a separate app-data directory next to its report. Use scripts/activity-check.py."]
            if let bytes = try? JSONSerialization.data(withJSONObject: failure) { try? bytes.write(to: url) }
            NSApp.terminate(nil); return
        }
        Task { await browserCheck(manager: manager, state: state, report: url) }
    }

    /// Explicit opt-in. Creates only disposable, neutral-site windows. No existing
    /// Edge window is adopted, enumerated for URLs, or closed.
    static func browserCheck(manager: ActivityManager, state: AppState, report: URL) async {
        var current = manager
        var results: [String: Any] = [:]
        var ids: [UUID] = []
        func require(_ value: Bool, _ key: String) throws {
            results[key] = value
            if !value { throw BrowserError.operation("Failed native browser check: \(key)") }
        }
        do {
            let a = Activity(name: "FrameDesk browser test A", websites: ["https://example.com/#framedesk-a", "https://example.org/#framedesk-second-tab"])
            let b = Activity(name: "FrameDesk browser test B", websites: ["https://example.org/#framedesk-b"])
            ids = [a.id, b.id]
            try require(current.save(a) && current.save(b), "activities_saved")
            await current.open(a.id, state: state)
            guard let sa = current.session(a.id) else { throw BrowserError.operation(current.error ?? "First window did not open") }
            let firstSnapshot = try await current.browser.snapshot(sa)
            try require(firstSnapshot.websites == a.websites, "multiple_website_tabs_opened")
            await current.open(b.id, state: state)
            guard let sb = current.session(b.id) else { throw BrowserError.operation(current.error ?? "Second window did not open") }
            try require(sa.windowID != sb.windowID, "activities_have_distinct_browser_windows")
            await current.open(a.id, state: state)
            try require(current.session(a.id)?.windowID == sa.windowID, "return_reuses_existing_window")
            _ = try await current.browser.snapshot(sb)
            current.setKeepOpen(a.id, true)
            await current.saveAndCloseWebsites(a.id)
            try require(current.session(a.id) != nil, "keep_open_blocks_close")
            current.setKeepOpen(a.id, false)
            await current.saveAndCloseWebsites(a.id)
            try require(current.session(a.id) == nil, "first_activity_saved_and_closed")
            let stillOpen = try await current.browser.snapshot(sb)
            try require(stillOpen.websites.first?.contains("framedesk-b") == true, "other_activity_stays_open")
            current = ActivityManager()
            try require(current.activities.first(where: { $0.id == a.id })?.websites == a.websites && current.session(a.id) == nil, "saved_activity_loaded_from_disk")
            try require(current.session(b.id)?.windowID == sb.windowID, "other_owned_session_survives_manager_reload")
            await current.open(a.id, state: state)
            try require(current.session(a.id)?.windowID != nil && current.session(a.id)?.windowID != sa.windowID, "saved_activity_reopens_in_new_window")
            let reopened = try await current.browser.snapshot(current.session(a.id)!)
            try require(reopened.websites == a.websites, "reopened_websites_match_saved_recipe")
        } catch { results["error"] = error.localizedDescription }
        for id in ids {
            current.setKeepOpen(id, false)
            await current.saveAndCloseWebsites(id)
        }
        results["test_windows_closed"] = ids.allSatisfy { current.session($0) == nil }
        results["native_edge_workspaces"] = "Not connected: no workspace operation in the installed Mac scripting dictionary. Only dedicated normal browser windows are supported."
        let bools = results.values.compactMap { $0 as? Bool }
        results["all_passed"] = !bools.isEmpty && bools.allSatisfy { $0 } && results["error"] == nil
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted,.sortedKeys]) { try? data.write(to: report, options: .atomic) }
        NSApp.terminate(nil)
    }
}
