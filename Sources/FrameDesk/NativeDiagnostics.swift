import AppKit
import ApplicationServices
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum NativeDiagnostics {
    static func permissions(report: URL) {
        let result: [String: Any] = [
            "accessibility": AXIsProcessTrusted(),
            "screen_recording": CGPreflightScreenCaptureAccess(),
            "bundle_path": Bundle.main.bundleURL.path,
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "process_id": ProcessInfo.processInfo.processIdentifier
        ]
        write(result, to: report)
        NSApp.terminate(nil)
    }

    /// Explicit local diagnostic: captures only the menu-bar and Dock strips.
    /// Does not move windows, click UI, capture audio, or publish images.
    static func iconEvidence(directory: URL) async {
        var result: [String: Any] = [:]
        do {
            guard CGPreflightScreenCaptureAccess() else { throw Failure("Screen Recording is not available to this build") }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displayID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { throw Failure("No display available") }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Let the application icon update reach the Dock before taking proof.
            try await Task.sleep(nanoseconds: 700_000_000)
            let height = CGFloat(display.height), width = CGFloat(display.width)
            let regions = [
                ("menu-bar", CGRect(x: 0, y: 0, width: width, height: min(40, height))),
                ("dock", CGRect(x: 0, y: max(0, height-150), width: width, height: min(150, height)))
            ]
            for (name, region) in regions {
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = region
                configuration.width = Int(region.width*2)
                configuration.height = Int(region.height*2)
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let url = directory.appendingPathComponent(name+".png")
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Failure("Could not create image destination") }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw Failure("Could not save icon evidence") }
                result[name] = url.path
            }
            result["images_saved"] = true
            result["scope"] = "Actual menu-bar and bottom Dock strips captured locally using ScreenCaptureKit; image inspection is required."
        } catch { result["error"] = error.localizedDescription; result["images_saved"] = false }
        write(result, to: directory.appendingPathComponent("result.json"))
        NSApp.terminate(nil)
    }

    private static func write(_ result: [String: Any], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: url, options: .atomic)
        } catch { NSLog("FrameDesk diagnostic could not write report: %@", error.localizedDescription) }
    }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
