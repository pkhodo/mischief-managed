import AppKit
import ApplicationServices
import FrameDeskCore
import Darwin

@MainActor
enum TilingDiagnostics {
    static func runIfRequested(state: AppState) {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--tiling-check"), args.indices.contains(flag+1) else { return }
        let report = URL(fileURLWithPath: args[flag+1])
        Task { await run(state: state, report: report) }
    }
    static func snapshotIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--tiling-ui-snapshot") ?? args.firstIndex(of:"--scenes-ui-snapshot"), args.indices.contains(flag+1) else { return }
        NSApp.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        DispatchQueue.main.asyncAfter(deadline: .now()+1.2) {
            guard let window = NSApp.windows.first(where: { $0.title == "Mischief Managed" }), let view = window.contentView else { Darwin.exit(1) }
            window.setContentSize(NSSize(width: 680, height: 1080)); view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { Darwin.exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            let canvas = NSImage(size: view.bounds.size)
            canvas.lockFocus(); NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: view.bounds).fill(); rep.draw(in: view.bounds); canvas.unlockFocus()
            guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let bytes = bitmap.representation(using: .png, properties: [:]) else { Darwin.exit(1) }
            do { try bytes.write(to: URL(fileURLWithPath: args[flag+1])); Darwin.exit(0) } catch { Darwin.exit(1) }
        }
    }
    private static func run(state: AppState, report: URL) async {
        var checks: [[String: Any]] = []
        var metadata: [String: Any] = ["bundle_path": Bundle.main.bundleURL.path, "accessibility": WindowManager.allowed, "capture_started": false]
        func check(_ name: String, _ passed: Bool) throws {
            checks.append(["name": name, "passed": passed])
            if !passed { throw Failure(name) }
        }
        let manager = state.tiling
        var original: [LiveWindow] = []
        do {
            guard let directory = ProcessInfo.processInfo.environment["FRAMEDESK_DATA_DIR"],
                  URL(fileURLWithPath: directory).standardizedFileURL == report.deletingLastPathComponent().appendingPathComponent("app-data").standardizedFileURL else { throw Failure("Diagnostic requires isolated app-data beside its report") }
            if let session = CGSessionCopyCurrentDictionary() as? [String: Any], (session["CGSSessionScreenIsLocked"] as? Bool) == true {
                throw Failure("The Mac is locked. Unlock it and leave the desktop visible before native window testing.")
            }
            try check("accessibility_available", WindowManager.allowed)
            for _ in 0..<30 {
                original = try WindowManager.scan(bundleIDs: ["com.pkhodo.FrameDeskTestCards"])
                if original.count == 2 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            metadata["fixture_scan_count"] = original.count
            metadata["display_count"] = Display.all.count
            if original.count != 2 {
                metadata["fixture_probe"] = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.pkhodo.FrameDeskTestCards" }.map { app -> [String: Any] in
                    let ax = AXUIElementCreateApplication(app.processIdentifier)
                    let windows = WindowManager.value(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
                    let cg = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                    return ["pid": app.processIdentifier, "regular": app.activationPolicy == .regular, "hidden": app.isHidden,
                            "ax_frames": windows.map { box(WindowManager.frame($0)) },
                            "cg_frames": cg.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier }.map { ["bounds": $0[kCGWindowBounds as String] ?? [:], "layer": $0[kCGWindowLayer as String] ?? -1, "alpha": $0[kCGWindowAlpha as String] ?? -1] }]
                }
            }
            guard original.count == 2, let display = Display.all.first else { throw Failure("Exactly two fixture windows and a display are required") }
            manager.start()
            let base = CGRect(x: display.visible.minX+180, y: display.visible.midY-160, width: 640, height: 360)
            let a = original[0], b = original[1]
            _ = WindowManager.move(a, to: base)
            _ = WindowManager.move(b, to: CGRect(x: display.visible.maxX-650, y: display.visible.minY+100, width: 560, height: 320))
            let untouched = WindowManager.frame(b.element)!
            manager.activate(scope: "fixture-a", name: "Test activity A", restore: false)
            manager.setGrid(TileGrid(preset: .quarters), scope: "fixture-a", name: "Test activity A", display: display.id)
            manager.setEnabled(true); manager.setShowGrid(true)
            try check("click_through_grid_visible", manager.overlayCount == Display.all.count && manager.overlayWindows.allSatisfy { $0.ignoresMouseEvents && !$0.canBecomeKey && !$0.canBecomeMain })
            var eventTrace:[String]=[];manager.onDiagnosticEvent={ if eventTrace.count<200 { eventTrace.append($0) } }
            var highlights = 0; manager.onDragHighlight = { _,_ in highlights += 1 }
            let target = manager.grid(display: display.id).frames(in: display.visible)[1]
            try await drag(a, manager:manager, to: CGPoint(x: target.midX, y: target.midY))
            metadata["first_drag_event_trace"]=eventTrace
            metadata["first_drag_actual"] = box(WindowManager.frame(a.element))
            metadata["first_drag_expected"] = box(target)
            metadata["status_after_drag"] = manager.status
            try check("real_drag_highlights_destination", highlights > 0)
            try check("real_drag_snaps_exact_window", near(WindowManager.frame(a.element), target))
            try check("other_fixture_window_unchanged", near(WindowManager.frame(b.element), untouched))
            let fileA = try manager.store.load()
            try check("snap_position_saved_to_disk", fileA.profiles["fixture-a"]?.windows.count == 1)
            manager.setGrid(TileGrid(preset: .thirds), scope: "fixture-a", name: "Test activity A", display: display.id)
            manager.undoLastMove()
            try check("undo_preserves_later_grid_edit", manager.grid(display: display.id).preset == .thirds)
            manager.setGrid(TileGrid(preset: .quarters), scope: "fixture-a", name: "Test activity A", display: display.id)
            try check("undo_restores_pre_drag_frame", near(WindowManager.frame(a.element), base))
            try check("undo_reverts_saved_assignment", try manager.store.load().profiles["fixture-a"]?.windows.isEmpty == true)
            // A visible grid must not intercept the second real drag or its Option bypass.
            try await drag(a, manager:manager, to: CGPoint(x: target.midX, y: target.midY), flags: .maskAlternate)
            try check("option_drag_bypasses_snapping", !near(WindowManager.frame(a.element), target) && manager.file.profiles["fixture-a"]?.windows.isEmpty == true)
            _ = WindowManager.move(a, to: base)
            manager.setRequireShift(true)
            try await drag(a, manager:manager, to: CGPoint(x: target.midX, y: target.midY))
            try check("shift_only_mode_ignores_normal_drag", manager.file.profiles["fixture-a"]?.windows.isEmpty == true)
            _ = WindowManager.move(a, to: base)
            try await drag(a, manager:manager, to: CGPoint(x: target.midX, y: target.midY), flags: .maskShift)
            try check("shift_drag_snaps", near(WindowManager.frame(a.element), target))
            manager.setRequireShift(false)
            // Resize from an actual bottom-right border. No new snap transaction may occur.
            let savedBeforeResize = manager.file.profiles["fixture-a"]
            let resizeStart = CGPoint(x: target.maxX-1, y: target.minY+1)
            try await mouse(from: resizeStart, to: CGPoint(x: resizeStart.x-120, y: resizeStart.y+80))
            try check("resize_is_not_a_snap", manager.file.profiles["fixture-a"] == savedBeforeResize && !near(WindowManager.frame(a.element), target))
            manager.activate(scope: "fixture-b", name: "Test activity B", restore: false)
            manager.setGrid(TileGrid(preset: .thirds), scope: "fixture-b", name: "Test activity B", display: display.id)
            try check("activity_grid_switches", manager.grid(display: display.id).preset == .thirds)
            manager.activate(scope: "fixture-a", name: "Test activity A")
            try check("activity_switch_restores_saved_tiled_window", near(WindowManager.frame(a.element), target) && manager.grid(display: display.id).preset == .quarters)
            // Same-title windows keep distinct saved records and exact live bindings.
            manager.activate(scope: "fixture-duplicates", name: "Duplicate title test", restore: false)
            manager.setGrid(TileGrid(preset: .quarters), scope: "fixture-duplicates", name: "Duplicate title test", display: display.id)
            let command = report.deletingLastPathComponent().appendingPathComponent("command.txt")
            try "duplicate".write(to: command, atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 350_000_000)
            _ = WindowManager.move(a, to: base)
            let secondTarget = manager.grid(display: display.id).frames(in: display.visible)[2]
            try await drag(a, manager:manager, to: CGPoint(x: target.midX, y: target.midY))
            try await drag(b, manager:manager, to: CGPoint(x: secondTarget.midX, y: secondTarget.midY))
            let duplicateSaved = try manager.store.load().profiles["fixture-duplicates"]?.windows ?? []
            try check("same_title_windows_keep_two_distinct_assignments", duplicateSaved.count == 2 && Set(duplicateSaved.map(\.id)).count == 2 && Set(duplicateSaved.map(\.title)).count == 1)
            _ = WindowManager.move(a, to: base); _ = WindowManager.move(b, to: untouched)
            let observable = await fixtureVisibility([a, b])
            try check("duplicate_restore_perturbation_observable", observable && near(WindowManager.frame(a.element), base) && near(WindowManager.frame(b.element), untouched))
            manager.restoreSavedWindows()
            metadata["duplicate_restore_status"] = manager.status
            metadata["duplicate_restore_a"] = box(WindowManager.frame(a.element))
            metadata["duplicate_restore_b"] = box(WindowManager.frame(b.element))
            try check("same_title_live_restore_uses_exact_handles", near(WindowManager.frame(a.element), target) && near(WindowManager.frame(b.element), secondTarget))
            // A new process cannot safely infer which identical title belongs to which
            // saved record. Retain both records, explicitly skip both windows.
            _ = WindowManager.move(a, to: base); _ = WindowManager.move(b, to: untouched)
            try check("ambiguous_reload_perturbation_observable", await fixtureVisibility([a, b]))
            let ambiguous = DesktopTilingManager(directory: manager.store.url.deletingLastPathComponent())
            ambiguous.restoreSavedWindows()
            try check("ambiguous_reload_preserves_records_and_skips_windows", ambiguous.file.profiles["fixture-duplicates"]?.windows.count == 2 && near(WindowManager.frame(a.element), base) && near(WindowManager.frame(b.element), untouched))
            try "unique".write(to: command, atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 350_000_000)
            manager.activate(scope: "fixture-a", name: "Test activity A")
            _ = WindowManager.move(a, to: base)
            manager.restoreSavedWindows(connectedDisplays: [])
            try check("missing_display_never_rehomes_window", near(WindowManager.frame(a.element), base))
            manager.stop()
            let reloaded = DesktopTilingManager(directory: manager.store.url.deletingLastPathComponent())
            try check("restart_perturbation_observable", await fixtureVisibility([a, b]))
            reloaded.start()
            try check("new_manager_loads_settings_and_restores_real_window", reloaded.enabled && reloaded.showGrid && reloaded.file.activeScope == "fixture-a" && near(WindowManager.frame(a.element), target))
            reloaded.setShowGrid(false)
            try check("grid_can_be_hidden", reloaded.overlayCount == 0)
            reloaded.setEnabled(false)
            _ = WindowManager.move(a, to: base)
            try await drag(a, manager:reloaded, to: CGPoint(x: target.midX, y: target.midY))
            try check("disabled_snapping_does_not_move_to_tile", !near(WindowManager.frame(a.element), target))
            let asymmetric=TileGrid(preset:.freeform,customZones:[
                Box(CGRect(x:0,y:0,width:0.61,height:1)),
                Box(CGRect(x:0.61,y:0.42,width:0.39,height:0.58)),
                Box(CGRect(x:0.68,y:0,width:0.32,height:0.32))])
            reloaded.setGrid(asymmetric,scope:"fixture-a",name:"Test activity A",display:display.id)
            reloaded.setEnabled(true); reloaded.setShowGrid(true)
            _ = WindowManager.move(a,to:base)
            try check("asymmetric_fixture_perturbation_observable", await fixtureVisibility([a,b]))
            let asymmetricTarget=asymmetric.frames(in:display.visible)[1]
            try await drag(a,manager:reloaded,to:CGPoint(x:asymmetricTarget.midX,y:asymmetricTarget.midY))
            try check("real_drag_snaps_into_asymmetric_tile", near(WindowManager.frame(a.element),asymmetricTarget))
            try check("asymmetric_grid_saved_exactly", try reloaded.store.load().profiles["fixture-a"]?.grids[display.id] == asymmetric)
            reloaded.stop()
            _ = WindowManager.move(a,to:base)
            try check("asymmetric_restart_perturbation_observable", await fixtureVisibility([a,b]))
            let asymmetricRestart=DesktopTilingManager(directory:manager.store.url.deletingLastPathComponent())
            asymmetricRestart.start()
            try check("asymmetric_grid_and_window_restore_after_reload", asymmetricRestart.grid(display:display.id) == asymmetric && near(WindowManager.frame(a.element),asymmetricTarget))
            asymmetricRestart.stop()
            let sceneManager=DesktopTilingManager(directory:manager.store.url.deletingLastPathComponent())
            sceneManager.start()
            let testHome=DisplayScene(name:"TEST Home",required:[display.id]),testWork=DisplayScene(name:"TEST Work",required:[display.id])
            try check("scene_registration_on_real_display",sceneManager.saveScene(testHome))
            let homeContext=sceneManager.currentContext
            let savedHome=sceneManager.currentProfile()
            try check("scene_auto_restore_is_opt_in",sceneManager.file.scenes?.autoRestore==false)
            try check("second_scene_registration_preserves_home",sceneManager.saveScene(testWork))
            sceneManager.setGrid(TileGrid(preset:.quarters),scope:"fixture-a",name:"Test activity A",display:display.id)
            _ = WindowManager.move(a,to:base)
            try check("scene_work_perturbation_observable",await fixtureVisibility([a,b]))
            try await drag(a,manager:sceneManager,to:CGPoint(x:target.midX,y:target.midY))
            try check("scene_work_window_has_its_own_position",near(WindowManager.frame(a.element),target))
            try check("scene_work_save_does_not_overwrite_home",sceneManager.file.profile(scope:"fixture-a",context:homeContext)==savedHome)
            try check("scene_change_rejects_captured_editor_target",!sceneManager.setGrid(TileGrid(preset:.halves),scope:"fixture-a",name:"Test activity A",display:display.id,context:homeContext))
            sceneManager.chooseScene(testHome.id)
            try check("scene_home_restores_its_distinct_real_window",near(WindowManager.frame(a.element),asymmetricTarget))
            sceneManager.refreshSceneDetection(snapshot:[SceneDisplay(id:"unknown-fixture",name:"Unregistered test display")],restore:true)
            try check("unknown_scene_does_not_move_real_window",sceneManager.currentContext == .unassigned && near(WindowManager.frame(a.element),asymmetricTarget))
            sceneManager.refreshSceneDetection()
            _ = WindowManager.move(a,to:base)
            try check("scene_auto_restore_perturbation_observable",await fixtureVisibility([a,b]))
            sceneManager.setAutomaticSceneRestore(true)
            sceneManager.refreshSceneDetection(restore:true)
            try check("scene_opted_in_restore_uses_known_scene",near(WindowManager.frame(a.element),asymmetricTarget))
            sceneManager.setAutomaticSceneRestore(false)
            let captureActivity = Activity(name: "Manually arranged")
            let arrangementFrame = CGRect(x: base.minX + 32, y: base.minY + 46, width: 701, height: 413)
            _ = WindowManager.move(a, to: arrangementFrame)
            try check("manual_arrangement_fixture_visible", await fixtureVisibility([a,b]))
            let otherBeforeSave = WindowManager.frame(b.element)
            let configuration = Display.all.map(DisplayConfiguration.init)
            let beforeRejectedSave = sceneManager.file
            let workContext = SceneContext(sceneID: testWork.id, variant: homeContext.variant)
            try check("manual_arrangement_rejects_different_scene", !sceneManager.saveArrangement([a], for: captureActivity, context: workContext, configuration: configuration))
            try check("manual_arrangement_rejection_preserves_file", sceneManager.file == beforeRejectedSave)
            try check("manual_arrangement_saved_from_live_window", sceneManager.saveArrangement([a], for: captureActivity, context: homeContext, configuration: configuration))
            try check("manual_save_does_not_move_either_window", near(WindowManager.frame(a.element), arrangementFrame) && WindowManager.frame(b.element) == otherBeforeSave)
            let capturedScope = captureActivity.id.uuidString
            let capturedFile = try sceneManager.store.load()
            try check("manual_arrangement_remembers_only_chosen_window_in_home", capturedFile.profile(scope: capturedScope, context: homeContext)?.windows.count == 1 && capturedFile.profile(scope: capturedScope, context: workContext) == nil)
            _ = WindowManager.move(a, to: base)
            try check("manual_arrangement_perturbation_observable", await fixtureVisibility([a,b]) && near(WindowManager.frame(a.element), base))
            sceneManager.activate(scope: capturedScope, name: captureActivity.name)
            try check("manual_arrangement_restores_unsnapped_frame", near(WindowManager.frame(a.element), arrangementFrame))
            sceneManager.activate(scope: "fixture-a", name: "Test activity A")
            sceneManager.stop()
            metadata["asymmetric_actual"] = box(WindowManager.frame(a.element))
            let defaultManager = DesktopTilingManager(directory: manager.store.url.deletingLastPathComponent().appendingPathComponent("automatic-snap"))
            defaultManager.setEnabled(false)
            defaultManager.setRequireShift(true)
            defaultManager.start(automaticallySnap: true)
            defer { defaultManager.stop() }
            try check("ordinary_mode_snaps_without_saved_enable_or_shift_settings", defaultManager.enabled && !defaultManager.requireShift && !defaultManager.file.enabled && defaultManager.file.requireShift)
            _ = WindowManager.move(a, to: base)
            try check("automatic_snap_fixture_visible", await fixtureVisibility([a,b]))
            try await drag(a, manager: defaultManager, to: CGPoint(x: target.midX, y: target.midY))
            try check("ordinary_mode_snaps_real_window_without_shift", near(WindowManager.frame(a.element), target))
            defaultManager.stop()
            metadata["scene_test_scope"]="Two independent scene profiles on the one actual display; synthetic unknown topology. Physical Home/Work/iPad reconnection is not claimed."
            metadata["cold_restore_expected"]=box(asymmetricTarget)
            try check("no_capture_started_for_tiling", !state.capturing && !state.busy)
        } catch { metadata["error"] = error.localizedDescription }
        manager.stop()
        for old in original { _ = WindowManager.move(old, to: old.frame) }
        metadata["checks"] = checks
        metadata["all_passed"] = !checks.isEmpty && checks.allSatisfy { $0["passed"] as? Bool == true } && metadata["error"] == nil
        do {
            try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
        } catch { NSLog("Tiling diagnostic report failed: %@", error.localizedDescription) }
        NSApp.terminate(nil)
    }
    private static func fixtureVisibility(_ windows: [LiveWindow]) async -> Bool {
        // AX writes and WindowServer bounds update separately. A restore test must
        // first prove that its deliberately perturbed windows are discoverable.
        for _ in 0..<30 {
            let live = (try? WindowManager.scan(bundleIDs: ["com.pkhodo.FrameDeskTestCards"])) ?? []
            if windows.allSatisfy({ old in live.contains { CFEqual($0.element, old.element) } }) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
    private static func drag(_ window: LiveWindow, manager:DesktopTilingManager, to point: CGPoint, flags: CGEventFlags = []) async throws {
        guard let frame = WindowManager.frame(window.element) else { throw Failure("Fixture disappeared") }
        var pid: pid_t = 0; AXUIElementGetPid(window.element, &pid)
        let activated=NSRunningApplication(processIdentifier: pid)?.activate(options: []) ?? false
        let raised=AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        manager.onDiagnosticEvent?("fixture activate=\(activated); raise=\(raised.rawValue)")
        // Activation can change menu-bar/work-area screen parameters. Prove the
        // real detector is stable before starting a drag; do not bypass its guard.
        var stable=0
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds:50_000_000)
            stable=manager.detectingScene ? 0 : stable+1
            if stable>=4 { break }
        }
        guard stable>=4 else { throw Failure("Display detection did not settle before fixture drag") }
        try await mouse(from: CGPoint(x: frame.midX, y: frame.maxY-13), to: point, flags: flags)
    }
    private static func mouse(from start: CGPoint, to end: CGPoint, flags: CGEventFlags = []) async throws {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ kind: CGEventType, at p: CGPoint) {
            let quartz = CGPoint(x: p.x, y: Display.primaryTop-p.y)
            let event = CGEvent(mouseEventSource: source, mouseType: kind, mouseCursorPosition: quartz, mouseButton: .left)
            event?.flags = flags; event?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, at: start); try await Task.sleep(nanoseconds: 80_000_000)
        post(.leftMouseDown, at: start); try await Task.sleep(nanoseconds: 150_000_000)
        for step in 1...24 {
            let amount = Double(step)/24
            post(.leftMouseDragged, at: CGPoint(x: start.x+(end.x-start.x)*amount, y: start.y+(end.y-start.y)*amount))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        post(.leftMouseUp, at: end); try await Task.sleep(nanoseconds: 450_000_000)
    }
    private static func near(_ frame: CGRect?, _ target: CGRect) -> Bool {
        guard let frame else { return false }
        return abs(frame.minX-target.minX) < 5 && abs(frame.minY-target.minY) < 5 && abs(frame.width-target.width) < 5 && abs(frame.height-target.height) < 5
    }
    private static func box(_ frame: CGRect?) -> [String: Double] {
        guard let frame else { return [:] }
        return ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
