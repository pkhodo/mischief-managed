import Foundation
import CoreGraphics

public enum TilePreset: String, Codable, CaseIterable, Sendable {
    case halves = "Halves", thirds = "Thirds", quarters = "Quarters", focus = "Focus", custom = "Custom", freeform = "Freeform"
}

public struct TileGrid: Codable, Equatable, Sendable {
    public var preset: TilePreset = .quarters
    public var columns = 2
    public var rows = 2
    public var focusFraction = 0.65
    public var customZones: [Box]?
    public init(preset: TilePreset = .quarters, columns: Int = 2, rows: Int = 2, focusFraction: Double = 0.65, customZones: [Box]? = nil) {
        self.preset = preset; self.columns = columns; self.rows = rows; self.focusFraction = focusFraction; self.customZones = customZones
    }
    public var isValid: Bool {
        (1...6).contains(columns) && (1...4).contains(rows) && focusFraction.isFinite && (0.3...0.8).contains(focusFraction)
        && (customZones.map(FreeformGeometry.valid) ?? (preset != .freeform))
    }
    public func asFreeform() -> TileGrid {
        var result = self
        result.customZones = preset == .freeform ? customZones : zones
        result.preset = .freeform
        return result
    }
    /// Ordered left-to-right, top-to-bottom. Coordinates use AppKit's upward Y axis.
    public var zones: [Box] {
        if preset == .freeform { return customZones ?? [] }
        if preset == .focus {
            return [Box(CGRect(x: 0, y: 0, width: focusFraction, height: 1)),
                    Box(CGRect(x: focusFraction, y: 0.5, width: 1-focusFraction, height: 0.5)),
                    Box(CGRect(x: focusFraction, y: 0, width: 1-focusFraction, height: 0.5))]
        }
        let c = preset == .halves ? 2 : preset == .thirds ? 3 : preset == .quarters ? 2 : columns
        let r = preset == .quarters ? 2 : preset == .custom ? rows : 1
        guard isValid else { return [] }
        return (0..<(c*r)).map { i in Box(CGRect(x: Double(i % c)/Double(c), y: 1-Double(i/c+1)/Double(r), width: 1/Double(c), height: 1/Double(r))) }
    }
    public func frames(in bounds: CGRect) -> [CGRect] {
        zones.map { zone in
            let cell = Geometry.expanded(zone, in: bounds)
            let gap = min(4, cell.width/10, cell.height/10)
            return cell.insetBy(dx: gap, dy: gap).integral.intersection(bounds)
        }
    }
    public func zone(at point: CGPoint, in bounds: CGRect) -> Int? {
        guard bounds.contains(point) else { return nil }
        return zones.indices.filter { Geometry.expanded(zones[$0], in: bounds).contains(point) }.min { a, b in
            let left = zones[a].width*zones[a].height, right = zones[b].width*zones[b].height
            return abs(left-right) < 0.00000001 ? a < b : left < right
        }
    }
}

public struct DesktopProfile: Codable, Equatable, Sendable {
    public var name: String
    public var grids: [String: TileGrid] = [:]
    public var windows: [Placement] = []
    public var capturedArrangement: Bool?
    public init(name: String) { self.name = name }
}

public struct DesktopTilingFile: Codable, Equatable, Sendable {
    public var version = 1
    public var enabled = false
    public var showGrid = false
    public var requireShift = false
    public var scenes: DisplaySceneLibrary?
    public var activeScope = "desktop"
    public var profiles: [String: DesktopProfile] = ["desktop": DesktopProfile(name: "Desktop")]
    public init() {}
}

public final class DesktopTilingStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> DesktopTilingFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return DesktopTilingFile() }
        let file = try JSONDecoder().decode(DesktopTilingFile.self, from: Data(contentsOf: url))
        try validate(file); return file
    }
    public func save(_ file: DesktopTilingFile) throws {
        try validate(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }
    private func validate(_ file: DesktopTilingFile) throws {
        guard file.version == 1, file.profiles[file.activeScope] != nil, file.profiles["desktop"] != nil,
              file.profiles.count <= 1000, file.profiles.allSatisfy({ !$0.key.isEmpty && $0.value.isValid }),
              file.scenes?.isValid ?? true else { throw TilingError.invalidData }
    }
}

public enum TilingError: LocalizedError {
    case invalidData
    public var errorDescription: String? { "The desktop tiling file is unreadable or unsupported. It has not been overwritten." }
}

public enum DesktopUndoGeometry {
    public static func target(original: CGRect, originalDisplays: [String: Box], currentDisplays: [String: Box], bounds: CGRect) -> CGRect {
        originalDisplays == currentDisplays ? original : Geometry.clamped(original, in: bounds)
    }
}
