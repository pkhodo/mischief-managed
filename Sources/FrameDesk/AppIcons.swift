import AppKit

enum AppIcons {
    static func installDockIcon() {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        // Supply the running application's icon explicitly as well as the bundle
        // icon. This avoids relying on an older LaunchServices icon representation.
        NSApplication.shared.applicationIconImage = image
        NSApplication.shared.dockTile.display()
    }

    static func menuBar(capturing: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 6, height: 14), xRadius: 1.3, yRadius: 1.3).fill()
            NSBezierPath(roundedRect: NSRect(x: 9, y: 10, width: 11, height: 6), xRadius: 1.3, yRadius: 1.3).fill()
            let area = NSBezierPath(roundedRect: NSRect(x: 11, y: 3, width: 7, height: 4), xRadius: 0.6, yRadius: 0.6)
            if capturing { area.fill() }
            else { area.lineWidth = 1; area.stroke() }
            NSColor.black.setStroke()
            for (x, y, sx, sy) in [(9.0,1.0,1.0,1.0),(20,1,-1,1),(9,9,1,-1),(20,9,-1,-1)] {
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x, y: y+sy*2)); p.line(to: NSPoint(x: x, y: y))
                p.line(to: NSPoint(x: x+sx*2, y: y)); p.lineWidth = 1
                p.lineJoinStyle = .round; p.lineCapStyle = .round; p.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = capturing ? "Mischief Managed, capture active" : "Mischief Managed"
        return image
    }
}
