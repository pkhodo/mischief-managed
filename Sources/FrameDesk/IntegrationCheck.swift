import AppKit
import IOSurface
import ApplicationServices
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import FrameDeskCore

/// Opt-in, real-API smoke check. It moves only the separately launched test-card windows.
@MainActor
enum IntegrationCheck {
    static func run(state: AppState, reportURL: URL) async {
        var results: [String:Any] = [:]
        func record(_ name: String, _ passed: Bool) { results[name] = passed }
        func wait(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds*1_000_000_000)) }
        do {
            guard WindowManager.allowed else { throw CheckError.failed("Accessibility is not allowed for this app build") }
            let original = try WindowManager.scan().filter { $0.placement.bundleID == "com.pkhodo.FrameDeskTestCards" }
            guard original.count == 2 else { throw CheckError.failed("Expected exactly two test cards") }
            guard !original[0].frame.intersects(original[1].frame) else { throw CheckError.failed("Test cards overlap; fix the fixture before trusting capture results") }
            let saved = Workspace(name: "Integration check", windows: original.map(\.placement), area: state.area)
            let store = WorkspaceStore(url: reportURL.deletingLastPathComponent().appendingPathComponent("integration-layout.json"))
            var file = WorkspaceFile(); file.layouts = [saved]
            try store.save(file)
            record("real_window_snapshot_saved_and_loaded", try store.load().layouts.first == saved)
            for old in original { _ = WindowManager.move(old, to: old.frame.offsetBy(dx: 30, dy: -20)) }
            // AX writes and WindowServer bounds settle independently. Prove the
            // perturbation is both applied and discoverable before restoring.
            var perturbedAndVisible = false
            for _ in 0..<40 {
                let visible = try WindowManager.scan()
                perturbedAndVisible = original.allSatisfy { old in
                    currentFrame(old.element, equals: old.frame.offsetBy(dx: 30, dy: -20))
                        && visible.contains { CFEqual($0.element, old.element) }
                }
                if perturbedAndVisible { break }
                await wait(0.05)
            }
            record("perturbed_windows_are_visible_before_restore", perturbedAndVisible)
            guard perturbedAndVisible else { throw CheckError.failed("Moved test cards did not settle into discoverable frames") }
            state.restore(saved)
            var restored = false
            for _ in 0..<40 {
                restored = original.allSatisfy { currentFrame($0.element, equals: $0.frame) }
                if restored { break }
                await wait(0.05)
            }
            record("saved_layout_restored_real_windows", restored)
            guard restored else { throw CheckError.failed("Saved layout did not restore the original test-card frames") }
            await wait()
            // Switch to identical titles, then tile only the second exact AX element.
            let command = reportURL.deletingLastPathComponent().appendingPathComponent("command.txt")
            try "duplicate".write(to: command, atomically: true, encoding: .utf8)
            await wait()
            state.openTilePicker()
            guard let second = state.pickerWindows.first(where: { CFEqual($0.element, original[1].element) }) else { throw CheckError.failed("Test card disappeared") }
            state.selectedWindows = [second.id]
            state.tileSelected()
            await wait()
            record("same_title_unselected_window_unchanged", currentFrame(original[0].element, equals: original[0].frame))
            record("same_title_selected_window_tiled", currentFrame(original[1].element, equals: state.region))
            state.restorePrevious()
            await wait()
            record("same_title_tile_undo_restores_exact_window", original.allSatisfy { currentFrame($0.element, equals: $0.frame) })
            // Capture samples from the actual ScreenCaptureKit stream, not a generated image.
            guard let display = state.display else { throw CheckError.failed("No display") }
            let inside = original.first(where: { $0.placement.title.hasPrefix("INSIDE") })!
            let outside = original.first(where: { $0.placement.title.hasPrefix("OUTSIDE") })!
            var lastColor: (r:Int,g:Int,b:Int)?
            var firstColor: (r:Int,g:Int,b:Int)?
            var phase = "inside"
            var expectedImageWritten = false
            var lastSize = CGSize.zero
            var frames = 0
            state.capture.diagnosticFrame = { surface in
                frames += 1
                lastSize = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
                guard IOSurfaceLock(surface, .readOnly, nil) == 0 else { return }
                defer { IOSurfaceUnlock(surface, .readOnly, nil) }
                let base = IOSurfaceGetBaseAddress(surface)
                let offset = IOSurfaceGetHeight(surface)/2 * IOSurfaceGetBytesPerRow(surface) + IOSurfaceGetWidth(surface)/5 * 4
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                lastColor = (Int(bytes[offset+2]), Int(bytes[offset+1]), Int(bytes[offset]))
                if frames == 1 {
                    firstColor = lastColor
                    let path = reportURL.deletingLastPathComponent().appendingPathComponent(phase+"-first-frame.png")
                    if saveFrame(surface, to: path) { results[phase+"_first_frame_path"] = path.path }
                }
                let expected = phase == "inside" ? isGreen(lastColor) : isRed(lastColor)
                if expected && !expectedImageWritten {
                    let path = reportURL.deletingLastPathComponent().appendingPathComponent(phase+"-expected-frame.png")
                    expectedImageWritten = saveFrame(surface, to: path)
                    if expectedImageWritten { results[phase+"_expected_frame_path"] = path.path }
                }
            }
            try await state.capture.start(display: display, region: inside.frame)
            // AX bounds can settle before WindowServer presents a moved window.
            // Require the fixture's actual pixels, with a bounded wait; receiving
            // the first complete buffer alone is not proof of its visible color.
            for _ in 0..<40 {
                if frames > 0 && isGreen(lastColor) { break }
                await wait(0.1)
            }
            record("screen_capture_received_real_frames", frames > 0)
            record("inside_region_is_green", isGreen(lastColor))
            results["inside_first_RGB"] = rgb(firstColor)
            results["inside_final_RGB"] = rgb(lastColor)
            let previewID = state.capture.diagnosticPreviewID
            phase = "outside"; frames = 0; firstColor = nil; lastColor = nil; expectedImageWritten = false
            try await state.capture.reframe(display: display, region: outside.frame)
            for _ in 0..<40 {
                if frames > 0 && isRed(lastColor) { break }
                await wait(0.1)
            }
            record("moving_and_resizing_region_updates_pixels", isRed(lastColor))
            results["outside_first_RGB"] = rgb(firstColor)
            results["outside_final_RGB"] = rgb(lastColor)
            record("reframing_keeps_same_shareable_window", previewID == state.capture.diagnosticPreviewID)
            record("resized_stream_matches_region", lastSize == Geometry.outputSize(region: outside.frame.size, scale: display.screen.backingScaleFactor))
            state.capture.stop()
            let stoppedFrames = frames
            await wait()
            record("stop_rejects_further_frames", frames == stoppedFrames)
            // Hold content enumeration at its await boundary. The content itself is real.
            let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            var entered = false; var released = false
            state.capture.contentProvider = {
                entered = true
                while !released { await wait(0.01) }
                return available
            }
            let pending = Task { try await state.capture.start(display: display, region: inside.frame) }
            for _ in 0..<100 where !entered { await wait(0.01) }
            guard entered else { throw CheckError.failed("Pending capture did not enter its content query") }
            state.capture.stop()
            released = true
            do { try await pending.value; record("pending_start_cancelled", false) }
            catch is CancellationError { record("pending_start_cancelled", true) }
            catch { record("pending_start_cancelled", false); results["pending_start_error"] = error.localizedDescription }
            entered = false; released = false
            state.startCapture()
            for _ in 0..<100 where !entered { await wait(0.01) }
            guard entered else { throw CheckError.failed("UI capture did not enter its content query") }
            state.stopCapture(); released = true
            await wait()
            record("cancelled_start_does_not_publish_ui_success", !state.capturing && !state.busy && state.status == "Capture paused")
            entered = false; released = true
            state.startCapture(); state.stopCapture()
            await wait()
            record("immediate_start_stop_never_enters_capture", !entered && !state.capturing && !state.busy && state.status == "Capture paused")
        } catch { results["error"] = error.localizedDescription }
        state.capture.stop(); state.showWindowPicker = false; state.editing = false; state.overlay.hide()
        let bools = results.values.compactMap { $0 as? Bool }
        results["all_passed"] = !bools.isEmpty && bools.allSatisfy { $0 } && results["error"] == nil
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted,.sortedKeys]) { try? data.write(to: reportURL, options: .atomic) }
        NSApp.terminate(nil)
    }
    private static func isGreen(_ color: (r:Int,g:Int,b:Int)?) -> Bool {
        color.map { $0.g > $0.r+30 && $0.g > $0.b+30 } ?? false
    }
    private static func isRed(_ color: (r:Int,g:Int,b:Int)?) -> Bool {
        color.map { $0.r > $0.g+30 && $0.r > $0.b+30 } ?? false
    }
    private static func rgb(_ color: (r:Int,g:Int,b:Int)?) -> [String:Int] {
        color.map { ["r":$0.r,"g":$0.g,"b":$0.b] } ?? [:]
    }
    /// The frame callback holds the IOSurface read lock. Copy before encoding so
    /// a later stream frame cannot mutate the image being saved for inspection.
    private static func saveFrame(_ surface: IOSurfaceRef, to url: URL) -> Bool {
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let stride = IOSurfaceGetBytesPerRow(surface)
        let bytes = Data(bytes: IOSurfaceGetBaseAddress(surface), count: stride*height)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
    private static func currentFrame(_ element: AXUIElement, equals expected: CGRect) -> Bool {
        guard let actual = WindowManager.frame(element) else { return false }
        return abs(actual.minX-expected.minX) < 5 && abs(actual.minY-expected.minY) < 5 && abs(actual.width-expected.width) < 5 && abs(actual.height-expected.height) < 5
    }
    enum CheckError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case let .failed(message) = self { return message }; return nil }
    }
}
