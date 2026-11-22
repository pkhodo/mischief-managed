import AppKit
import FrameDeskCore

final class Cards: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var timer: Timer?
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.dropFirst().first ?? NSTemporaryDirectory())
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        guard let screen = NSScreen.screens.first else { NSApp.terminate(nil); return }
        let stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FrameDesk/workspaces.json")
        let saved = try? WorkspaceStore(url: stateURL).load()
        let inside = saved?.area.map { Geometry.expanded($0.normalized, in: screen.frame) }
            ?? CGRect(x: screen.frame.midX, y: screen.frame.midY-30, width: screen.frame.width/2, height: screen.frame.height/2)
        make(title: "INSIDE — FrameDesk test", frame: inside, color: .systemGreen)
        make(title: "OUTSIDE — FrameDesk test", frame: CGRect(x: screen.visibleFrame.minX+40, y: screen.visibleFrame.minY+40, width: 480, height: 270), color: .systemRed)
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }
    func make(title: String, frame: CGRect, color: NSColor) {
        let window = NSWindow(contentRect: frame, styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.title = title; window.isReleasedWhenClosed = false
        let view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = color.cgColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 28, weight: .bold); label.textColor = .black
        label.frame = CGRect(x: 24, y: 60, width: max(400, frame.width-48), height: 60)
        view.addSubview(label); window.contentView = view
        window.setFrame(frame, display: true); window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }
    func tick() {
        let command = directory.appendingPathComponent("command.txt")
        if let text = try? String(contentsOf: command, encoding: .utf8) {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "duplicate": windows.forEach { $0.title = "Same title — FrameDesk test" }
            case "unique":
                for (i, window) in windows.enumerated() { window.title = i == 0 ? "INSIDE — FrameDesk test" : "OUTSIDE — FrameDesk test" }
            default: break
            }
        }
        let frames = windows.enumerated().map { i,w in ["index":i,"number":w.windowNumber,"title":w.title,"x":w.frame.minX,"y":w.frame.minY,"width":w.frame.width,"height":w.frame.height] as [String:Any] }
        if let data = try? JSONSerialization.data(withJSONObject: frames, options: .prettyPrinted) { try? data.write(to: directory.appendingPathComponent("fixture-frames.json"), options: .atomic) }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("quit").path) { NSApp.terminate(nil) }
    }
}
let application = NSApplication.shared
let delegate = Cards()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
