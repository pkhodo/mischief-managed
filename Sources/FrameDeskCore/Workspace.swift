import Foundation
import CoreGraphics

public struct Box: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

public enum Geometry {
    public static func normalized(_ rect: CGRect, in bounds: CGRect) -> Box {
        Box(CGRect(x: (rect.minX - bounds.minX) / bounds.width,
                   y: (rect.minY - bounds.minY) / bounds.height,
                   width: rect.width / bounds.width, height: rect.height / bounds.height))
    }
    public static func expanded(_ rect: Box, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + rect.x * bounds.width, y: bounds.minY + rect.y * bounds.height,
               width: rect.width * bounds.width, height: rect.height * bounds.height)
    }
    public static func clamped(_ rect: CGRect, in bounds: CGRect, minimum: CGSize = CGSize(width: 160, height: 90)) -> CGRect {
        let width = min(bounds.width, max(minimum.width, rect.width))
        let height = min(bounds.height, max(minimum.height, rect.height))
        return CGRect(x: min(max(bounds.minX, rect.minX), bounds.maxX - width),
                      y: min(max(bounds.minY, rect.minY), bounds.maxY - height), width: width, height: height)
    }
    /// AppKit has an upward Y axis; Accessibility has a downward Y axis from the primary display's top.
    public static func flipped(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
    /// ScreenCaptureKit source rectangles are display-local points, with a top-left origin.
    public static func sourceRect(_ region: CGRect, display: CGRect) -> CGRect {
        CGRect(x: region.minX - display.minX, y: display.maxY - region.maxY, width: region.width, height: region.height)
    }
    public static func outputSize(region: CGSize, scale: CGFloat) -> CGSize {
        let factor = min(max(1, scale), 1920 / region.width, 1080 / region.height)
        return CGSize(width: max(2, Int(region.width * factor) / 2 * 2), height: max(2, Int(region.height * factor) / 2 * 2))
    }
    public static func tiles(count: Int, in bounds: CGRect, gap: CGFloat = 8) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = count == 1 ? 1 : Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let w = (bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let h = (bounds.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
        return (0..<count).map { i in
            CGRect(x: bounds.minX + CGFloat(i % columns) * (w + gap),
                   y: bounds.maxY - CGFloat(i / columns + 1) * h - CGFloat(i / columns) * gap,
                   width: w, height: h).intersection(bounds)
        }
    }
}

public struct SavedArea: Codable, Equatable, Sendable {
    public var displayID: String
    public var normalized: Box
    public init(displayID: String, normalized: Box) { self.displayID = displayID; self.normalized = normalized }
}
public struct Placement: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var bundleID: String
    public var appName: String
    public var title: String
    public var ordinal: Int
    public var displayID: String
    public var normalized: Box
    public init(bundleID: String, appName: String, title: String, ordinal: Int, displayID: String, normalized: Box) {
        id = UUID(); self.bundleID = bundleID; self.appName = appName; self.title = title
        self.ordinal = ordinal; self.displayID = displayID; self.normalized = normalized
    }
}
public struct Workspace: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var windows: [Placement]
    public var area: SavedArea?
    public init(name: String, windows: [Placement], area: SavedArea?) {
        id = UUID(); self.name = name; createdAt = Date(); self.windows = windows; self.area = area
    }
}
public struct WorkspaceFile: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var layouts: [Workspace] = []
    public var area: SavedArea?
    public init() {}
}

public final class WorkspaceStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> WorkspaceFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return WorkspaceFile() }
        let file = try JSONDecoder().decode(WorkspaceFile.self, from: Data(contentsOf: url))
        guard file.version == 1 else { throw StoreError.unsupportedVersion }
        guard file.layouts.allSatisfy({ $0.windows.allSatisfy({ $0.normalized.isValid }) && ($0.area?.normalized.isValid ?? true) }),
              file.area?.normalized.isValid ?? true else { throw StoreError.invalidGeometry }
        return file
    }
    public func save(_ file: WorkspaceFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }
    public enum StoreError: LocalizedError {
        case unsupportedVersion, invalidGeometry
        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion: return "This layout file belongs to a newer FrameDesk version. It has not been changed."
            case .invalidGeometry: return "The layout file contains an invalid window rectangle. It has not been changed."
            }
        }
    }
}

public enum WindowMatching {
    /// Prefer titles. A changed title is safe to fall back only when both sides have one window.
    public static func match(saved: [Placement], live: [Placement]) -> [(saved: Int, live: Int)] {
        var available = Set(live.indices)
        var result: [(Int, Int)] = []
        for i in saved.indices {
            let candidates = available.filter { live[$0].bundleID == saved[i].bundleID && live[$0].title == saved[i].title }
            let sameSavedTitle = saved.filter { $0.bundleID == saved[i].bundleID && $0.title == saved[i].title }
            if candidates.count == 1, sameSavedTitle.count == 1, let j = candidates.first {
                result.append((i,j)); available.remove(j)
            }
        }
        let matched = Set(result.map(\.0))
        for i in saved.indices where !matched.contains(i) {
            let sameSaved = saved.filter { $0.bundleID == saved[i].bundleID }
            let sameLive = available.filter { live[$0].bundleID == saved[i].bundleID }
            if sameSaved.count == 1, live.filter({ $0.bundleID == saved[i].bundleID }).count == 1, let j = sameLive.first {
                result.append((i,j)); available.remove(j)
            }
        }
        return result.map { (saved: $0.0, live: $0.1) }
    }
}
