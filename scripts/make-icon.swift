// Original FrameDesk geometric artwork. Rebuild with:
// swift -module-cache-path /private/tmp/framedesk-icon-cache scripts/make-icon.swift
// AppKit draws the same vector geometry at every required macOS icon size.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255,
            green: CGFloat((hex >> 8) & 255)/255,
            blue: CGFloat(hex & 255)/255, alpha: alpha)
}
func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}
func gradient(_ path: NSBezierPath, _ top: UInt32, _ bottom: UInt32) {
    NSGradient(starting: color(bottom), ending: color(top))!.draw(in: path, angle: 90)
}
func tile(_ rect: NSRect, top: UInt32, bottom: UInt32, radius: CGFloat = 38) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x020612, 0.45)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(bottom).setFill(); rounded(rect, radius).fill()
    NSGraphicsContext.restoreGraphicsState()
    gradient(rounded(rect, radius), top, bottom)
    color(0xFFFFFF, 0.48).setStroke()
    let highlight = rounded(rect.insetBy(dx: 1, dy: 1), radius-1)
    highlight.lineWidth = 2; highlight.stroke()
}

func render(_ size: Int, url: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(size)/1024); transform.concat()
    NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    let base = rounded(NSRect(x: 80, y: 80, width: 864, height: 864), 194)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0x030817, 0.38)
    shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -18); shadow.set()
    color(0x101A32).setFill(); base.fill()
    NSGraphicsContext.restoreGraphicsState()
    gradient(base, 0x243957, 0x0A142A)
    color(0xFFFFFF, 0.18).setStroke(); base.lineWidth = 2; base.stroke()

    // A spacious layout: one tall document, one reference window, one capture quadrant.
    tile(NSRect(x: 228, y: 244, width: 222, height: 536), top: 0xFFFFFF, bottom: 0xCBDDED)
    tile(NSRect(x: 480, y: 514, width: 316, height: 266), top: 0x9AE9F2, bottom: 0x54B5D4)
    tile(NSRect(x: 494, y: 244, width: 288, height: 236), top: 0xFFBF70, bottom: 0xF27A37, radius: 30)

    // Four outward capture brackets make the selected quarter distinct from a tile.
    color(0xFFB461).setStroke()
    for (x, y, sx, sy) in [(476.0,226.0,1.0,1.0), (800,226,-1,1), (476,498,1,-1), (800,498,-1,-1)] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x, y: y+sy*46)); p.line(to: NSPoint(x: x, y: y))
        p.line(to: NSPoint(x: x+sx*46, y: y))
        p.lineWidth = 10; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    let cg = bitmap.cgImage!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    let provenance = "Original FrameDesk window-tiles/capture-quadrant artwork rendered from scripts/make-icon.swift; no external or generated image assets."
    CGImageDestinationAddImage(destination, cg, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: provenance]] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write icon") }
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(points*scale, url: iconset.appendingPathComponent(name))
    }
}
try render(1024, url: resources.appendingPathComponent("AppIcon.png"))
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit(); guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Created AppIcon.png and AppIcon.icns (all 10 macOS representations).")
