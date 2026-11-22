import AppKit
import FrameDeskCore

final class RegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RegionOverlay {
    let panel: RegionPanel
    let view: RegionView
    init() {
        panel = RegionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        view = RegionView()
        panel.contentView = view
    }
    func show(frame: CGRect, editable: Bool, bounds: CGRect) {
        panel.setFrame(frame, display: true)
        panel.ignoresMouseEvents = !editable
        view.editable = editable; view.allowedBounds = bounds
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}

final class RegionView: NSView {
    var editable = true
    var allowedBounds = CGRect.zero
    var onMove: ((CGRect) -> Void)?
    var onCommit: ((CGRect) -> Void)?
    var onFinish: (() -> Void)?
    private var startPoint = CGPoint.zero
    private var startFrame = CGRect.zero
    private var edges = (left: false, right: false, top: false, bottom: false)
    override var acceptsFirstResponder: Bool { editable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { editable }
    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Meeting capture area. Use the geometry fields in Mischief Managed as a keyboard alternative to dragging.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setStroke()
        let boundary = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        boundary.lineWidth = 3; boundary.stroke()
        guard editable else { return }
        let points = [CGPoint(x: 4, y: 4), CGPoint(x: bounds.maxX-4, y: 4), CGPoint(x: 4, y: bounds.maxY-4), CGPoint(x: bounds.maxX-4, y: bounds.maxY-4)]
        NSColor.systemOrange.setFill()
        for p in points { NSBezierPath(rect: CGRect(x: p.x-4, y: p.y-4, width: 8, height: 8)).fill() }
        let text = "Move area · drag an edge to resize · Esc to lock"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attrs)
        let label = CGRect(x: 12, y: bounds.maxY-40, width: min(size.width+20, bounds.width-24), height: 28)
        NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect: label, xRadius: 5, yRadius: 5).fill()
        text.draw(in: label.insetBy(dx: 10, dy: 5), withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) {
        guard editable, let window else { return }
        window.makeFirstResponder(self)
        startPoint = NSEvent.mouseLocation; startFrame = window.frame
        let p = convert(event.locationInWindow, from: nil)
        edges = (p.x < 18, p.x > bounds.width-18, p.y > bounds.height-18, p.y < 18)
    }
    override func mouseDragged(with event: NSEvent) {
        guard editable else { return }
        let now = NSEvent.mouseLocation; let dx = now.x-startPoint.x; let dy = now.y-startPoint.y
        var next = startFrame
        if !edges.left && !edges.right && !edges.top && !edges.bottom {
            next.origin.x += dx; next.origin.y += dy
        } else {
            if edges.left { next.origin.x += dx; next.size.width -= dx }
            if edges.right { next.size.width += dx }
            if edges.bottom { next.origin.y += dy; next.size.height -= dy }
            if edges.top { next.size.height += dy }
            if next.width < 240 { if edges.left { next.origin.x = startFrame.maxX-240 }; next.size.width = 240 }
            if next.height < 135 { if edges.bottom { next.origin.y = startFrame.maxY-135 }; next.size.height = 135 }
        }
        next = Geometry.clamped(next, in: allowedBounds, minimum: CGSize(width: 240, height: 135))
        window?.setFrame(next, display: true)
        onMove?(next)
    }
    override func mouseUp(with event: NSEvent) { if let frame = window?.frame { onCommit?(frame) } }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(); return }
        guard let frame = window?.frame else { return }
        var next = frame
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: next.origin.x -= step
        case 124: next.origin.x += step
        case 125: next.origin.y -= step
        case 126: next.origin.y += step
        default: super.keyDown(with: event); return
        }
        next = Geometry.clamped(next, in: allowedBounds)
        window?.setFrame(next, display: true); onMove?(next); onCommit?(next)
    }
    override func resetCursorRects() {
        guard editable else { return }
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(CGRect(x: 0, y: 0, width: 15, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: bounds.width-15, y: 0, width: 15, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: 0, y: 0, width: bounds.width, height: 15), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: 0, y: bounds.height-15, width: bounds.width, height: 15), cursor: .resizeUpDown)
    }
}
