import AppKit
import ApplicationServices
import FrameDeskCore

struct Display: Identifiable {
    let screen: NSScreen
    let number: CGDirectDisplayID
    let id: String
    var name: String { screen.localizedName }
    var frame: CGRect { screen.frame }
    var visible: CGRect { screen.visibleFrame }
    var sceneDisplay: SceneDisplay { SceneDisplay(id:id,name:name,builtIn:CGDisplayIsBuiltin(number) != 0,main:number==CGMainDisplayID(),frame:Box(frame)) }
    static var all: [Display] {
        NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let number = n.uint32Value
            let uuid = CGDisplayCreateUUIDFromDisplayID(number).takeRetainedValue()
            return Display(screen: screen, number: number, id: CFUUIDCreateString(nil, uuid) as String)
        }
    }
    static var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
}

// Freeze values rather than retaining NSScreen's mutable frame/visibleFrame.
struct DisplayConfiguration: Equatable {
    var id:String
    var frame:Box
    var visible:Box
    var scale:CGFloat
    var main:Bool
    var builtIn:Bool
    init(_ display:Display) {
        id=display.id;frame=Box(display.frame);visible=Box(display.visible)
        scale=display.screen.backingScaleFactor
        main=display.number==CGMainDisplayID();builtIn=CGDisplayIsBuiltin(display.number) != 0
    }
    func hasSameDisplay(as other: DisplayConfiguration) -> Bool {
        id == other.id && frame == other.frame && scale == other.scale && main == other.main && builtIn == other.builtIn
    }

}

struct LiveWindow: Identifiable {
    let id: UUID
    let element: AXUIElement
    let placement: Placement
    let frame: CGRect
    var label: String { "\(placement.appName) — \(placement.title.isEmpty ? "Untitled window" : placement.title)" }
}

enum WindowError: LocalizedError {
    case permission, noWindows
    var errorDescription: String? {
        switch self {
        case .permission: return "Allow Mischief Managed in System Settings → Privacy & Security → Accessibility, then refresh permissions."
        case .noWindows: return "No resizable windows were found on the current desktop. Open the windows you want to save and try again."
        }
    }
}

enum WindowManager {
    static var allowed: Bool { AXIsProcessTrusted() }
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let rawPosition = value(element, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = value(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size), size.width > 80, size.height > 40 else { return nil }
        return Geometry.flipped(CGRect(origin: point, size: size), primaryTop: Display.primaryTop)
    }
    static func scan(bundleIDs: Set<String>? = nil) throws -> [LiveWindow] {
        guard allowed else { throw WindowError.permission }
        let displays = Display.all
        let cgWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visible = cgWindows.filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }
        var result: [LiveWindow] = []
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isHidden }
        for app in apps {
            guard let bundle = app.bundleIdentifier else { continue }
            if let bundleIDs, !bundleIDs.contains(bundle) { continue }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.7)
            guard let windows = value(application, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for (ordinal, window) in windows.enumerated() {
                guard (value(window, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
                      (value(window, kAXMinimizedAttribute) as? Bool) != true,
                      (value(window, "AXFullScreen") as? Bool) != true,
                      let frame = frame(window) else { continue }
                // Bounds work without screen-title permission. Avoid windows from other Spaces.
                let quartz = Geometry.flipped(frame, primaryTop: Display.primaryTop)
                let onScreen = visible.contains { info in
                    guard (info[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                          let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                          let r = CGRect(dictionaryRepresentation: bounds) else { return false }
                    return abs(r.minX - quartz.minX) < 4 && abs(r.minY - quartz.minY) < 4
                        && abs(r.width - quartz.width) < 4 && abs(r.height - quartz.height) < 4
                }
                guard onScreen, let display = displays.max(by: { frame.intersection($0.visible).area < frame.intersection($1.visible).area }),
                      frame.intersection(display.visible).area > 0 else { continue }
                let title = value(window, kAXTitleAttribute) as? String ?? ""
                let placement = Placement(bundleID: bundle, appName: app.localizedName ?? bundle, title: title,
                                          ordinal: ordinal, displayID: display.id,
                                          normalized: Geometry.normalized(frame, in: display.visible))
                result.append(LiveWindow(id: placement.id, element: window, placement: placement, frame: frame))
            }
        }
        return result.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
    static func move(_ window: LiveWindow, to target: CGRect) -> Bool {
        let quartz = Geometry.flipped(target, primaryTop: Display.primaryTop)
        var position = quartz.origin; var size = quartz.size
        guard let p = AXValueCreate(.cgPoint, &position), let s = AXValueCreate(.cgSize, &size) else { return false }
        let sizeResult = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, s)
        let positionResult = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, p)
        // Some apps resize only after moving to the destination display.
        _ = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, s)
        guard sizeResult == .success, positionResult == .success, let actual = frame(window.element) else { return false }
        return abs(actual.minX - target.minX) < 5 && abs(actual.minY - target.minY) < 5
            && abs(actual.width - target.width) < 5 && abs(actual.height - target.height) < 5
    }
}

extension CGRect {
    var area: CGFloat { isNull || isInfinite ? 0 : max(0, width) * max(0, height) }
}
