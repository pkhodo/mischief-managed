import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import IOSurface
import FrameDeskCore

final class PreviewCanvas: NSView {
    let picture = CALayer()
    private let paused = NSTextField(labelWithString: "Capture paused")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        picture.contentsGravity = .resizeAspect
        picture.magnificationFilter = .linear
        layer?.addSublayer(picture)
        paused.textColor = .white
        paused.font = .systemFont(ofSize: 18, weight: .medium)
        paused.alignment = .center
        addSubview(paused)
        setAccessibilityLabel("Meeting preview. Share this window in your meeting app.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.frame = bounds
        CATransaction.commit()
        paused.frame = CGRect(x: 0, y: bounds.midY - 15, width: bounds.width, height: 30)
    }
    func show(_ surface: IOSurfaceRef) {
        paused.isHidden = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.contents = surface
        CATransaction.commit()
    }
    func clear(_ message: String = "Capture paused") {
        picture.contents = nil
        paused.stringValue = message; paused.isHidden = false
    }
}

final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((IOSurfaceRef) -> Void)?
    var onStop: ((Error) -> Void)?
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStop?(error) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in self?.onFrame?(surface) }
    }
}

@MainActor
final class CaptureController: NSObject, NSWindowDelegate {
    private var stream: SCStream?
    private var output: CaptureOutput?
    private var token = UUID()
    private var preview: NSWindow?
    private var canvas: PreviewCanvas?
    private var display: SCDisplay?
    private var scale: CGFloat = 1
    private var transitioning = false
    var onStatus: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var diagnosticFrame: ((IOSurfaceRef) -> Void)?
    var diagnosticPreviewID: Int? { preview?.windowNumber }
    var contentProvider: () async throws -> SCShareableContent = {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }

    func showPreview(region: CGRect) {
        guard region.width > 0, region.height > 0 else { return }
        if preview == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Mischief Managed — Share this window"
            window.tabbingMode = .disallowed
            window.minSize = CGSize(width: 320, height: 220)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("FrameDeskPreview")
            let view = PreviewCanvas(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
            window.contentView = view; canvas = view; preview = window
            // Keep the first preview away from the default top-right capture area.
            if let screen = NSScreen.main {
                window.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 28, y: screen.visibleFrame.minY + 28))
            }
        }
        preview?.contentAspectRatio = region.size
        preview?.makeKeyAndOrderFront(nil)
    }
    private func configuration(region: CGRect, displayFrame: CGRect) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = Geometry.sourceRect(region, display: displayFrame)
        let size = Geometry.outputSize(region: region.size, scale: scale)
        config.width = Int(size.width); config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = false
        return config
    }
    func start(display target: Display, region: CGRect) async throws {
        let request = UUID()
        token = request
        transitioning = true
        defer { if token == request { transitioning = false } }
        let previous = stream
        stream = nil; output = nil
        showPreview(region: region)
        canvas?.clear("Waiting for screen permission…")
        do {
            try? await previous?.stopCapture()
            try requireCurrent(request)
            let content = try await contentProvider()
            try requireCurrent(request)
            guard let source = content.displays.first(where: { $0.displayID == target.number }) else {
                throw CaptureError.displayMissing
            }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            guard !ownApps.isEmpty else { throw CaptureError.filterMissing }
            // Exclude the whole process, including future preview/control/overlay windows.
            let filter = SCContentFilter(display: source, excludingApplications: ownApps, exceptingWindows: [])
            scale = CGFloat(filter.pointPixelScale)
            let config = configuration(region: region, displayFrame: target.frame)
            let sink = CaptureOutput()
            var first = true
            sink.onFrame = { [weak self] surface in
                guard let self, self.token == request, !self.transitioning else { return }
                self.canvas?.show(surface)
                self.diagnosticFrame?(surface)
                if first { first = false; self.onFirstFrame?() }
            }
            sink.onStop = { [weak self] error in
                guard let self, self.token == request else { return }
                self.stop()
                self.canvas?.clear("Capture stopped")
                self.onFailure?(error.localizedDescription)
            }
            let newStream = SCStream(filter: filter, configuration: config, delegate: sink)
            try newStream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "FrameDesk.frames", qos: .userInteractive))
            stream = newStream; output = sink; display = source
            try await newStream.startCapture()
            guard token == request else {
                try? await newStream.stopCapture()
                throw CancellationError()
            }
            canvas?.clear("Waiting for the first frame…")
            onStatus?("Starting preview…")
        } catch {
            if token == request {
                let failed = stream
                stream = nil; output = nil; display = nil
                canvas?.clear("Capture could not start")
                Task { try? await failed?.stopCapture() }
            }
            throw error
        }
    }
    private func requireCurrent(_ request: UUID) throws {
        guard token == request, !Task.isCancelled else { throw CancellationError() }
    }
    /// Restart the source in the same preview window: no meeting-window reselection is needed.
    /// Old-session buffers are rejected by token, so the previous area cannot flash after a move.
    func reframe(display target: Display, region: CGRect) async throws {
        try await start(display: target, region: region)
    }
    func stop() {
        token = UUID()
        transitioning = false
        let previous = stream
        stream = nil; output = nil; display = nil
        canvas?.clear()
        Task { try? await previous?.stopCapture() }
    }
    func pauseForEditing() {
        stop(); canvas?.clear("Adjusting capture area…")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?(); return true
    }
    enum CaptureError: LocalizedError {
        case displayMissing, filterMissing
        var errorDescription: String? {
            switch self {
            case .displayMissing: return "The selected display disconnected. Choose an available display and start again."
            case .filterMissing: return "Mischief Managed could not exclude its own windows. Capture has not started; reopen Mischief Managed and try again."
            }
        }
    }
}
