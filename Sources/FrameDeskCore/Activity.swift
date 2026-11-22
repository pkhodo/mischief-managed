import Foundation

public enum ActivityArrangement: String, CaseIterable, Sendable {
    case current = "Keep positions"
    case columns = "Columns"
    case grid = "Grid"
    public func frames(count: Int, in bounds: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        if self == .grid { return Geometry.tiles(count: count, in: bounds) }
        let gap = min(8, bounds.width / Double(count * 2))
        let width = (bounds.width - Double(count-1) * gap) / Double(count)
        return (0..<count).map { CGRect(x: bounds.minX + Double($0) * (width+gap), y: bounds.minY, width: width, height: bounds.height).intersection(bounds) }
    }
}

public struct Activity: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var windows: [Placement]
    public var area: SavedArea?
    public var websites: [String]
    public var browserBounds: Box?
    public var favorite: Bool
    public var keepOpen: Bool
    public var lastOpened: Date?

    public init(name: String, windows: [Placement] = [], area: SavedArea? = nil, websites: [String] = []) {
        id = UUID(); self.name = name; self.windows = windows; self.area = area; self.websites = websites
        favorite = false; keepOpen = false
    }
    public init(legacy: Workspace) {
        self.init(name: legacy.name, windows: legacy.windows, area: legacy.area)
        id = legacy.id
    }
    public var workspace: Workspace { Workspace(name: name, windows: windows, area: area) }
}

/// A browser window belongs to an activity only within the exact browser launch
/// in which FrameDesk created it. IDs alone can be reused after a browser restart.
public struct ActivityBrowserSession: Codable, Equatable, Sendable {
    public var activityID: UUID
    public var windowID: Int
    public var processID: Int32
    public var launchedAt: Date
    public init(activityID: UUID, windowID: Int, processID: Int32, launchedAt: Date) {
        self.activityID = activityID; self.windowID = windowID
        self.processID = processID; self.launchedAt = launchedAt
    }
    public func belongs(to processID: Int32, launchedAt: Date) -> Bool {
        self.processID == processID && abs(self.launchedAt.timeIntervalSince(launchedAt)) < 0.001
    }
}

public struct ActivityFile: Codable, Equatable, Sendable {
    public var version = 1
    public var activities: [Activity] = []
    public var sessions: [ActivityBrowserSession] = []
    public init() {}
}

public enum WebsiteList {
    public static func parse(_ text: String) throws -> [String] {
        try text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.map(normalize)
    }
    public static func normalize(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = trimmed.contains(":") ? trimmed : "https://" + trimmed
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }),
              let parts = URLComponents(string: input), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              let url = parts.url else { throw ActivityError.invalidWebsite(value) }
        return url.absoluteString
    }
}

public enum ActivityError: LocalizedError {
    case invalidWebsite(String), invalidData
    public var errorDescription: String? {
        switch self {
        case .invalidWebsite(let text): return "“\(text)” is not a website address. Use an http:// or https:// address without a username or password."
        case .invalidData: return "The activities file is unreadable or belongs to another version. It has not been changed."
        }
    }
}

public final class ActivityStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load(legacy: [Workspace] = []) throws -> ActivityFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            var imported = ActivityFile(); imported.activities = legacy.map(Activity.init(legacy:))
            return imported
        }
        let data = try JSONDecoder().decode(ActivityFile.self, from: Data(contentsOf: url))
        try validate(data)
        return data
    }
    public func save(_ file: ActivityFile) throws {
        try validate(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }
    private func validate(_ file: ActivityFile) throws {
        guard file.version == 1, Set(file.activities.map(\.id)).count == file.activities.count,
              Set(file.sessions.map(\.activityID)).count == file.sessions.count,
              Set(file.sessions.map { "\($0.processID):\($0.launchedAt.timeIntervalSince1970):\($0.windowID)" }).count == file.sessions.count else { throw ActivityError.invalidData }
        for a in file.activities {
            guard !a.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  a.windows.allSatisfy({ $0.normalized.isValid }), a.area?.normalized.isValid ?? true,
                  a.browserBounds?.isValid ?? true else { throw ActivityError.invalidData }
            _ = try a.websites.map(WebsiteList.normalize)
        }
        for session in file.sessions {
            guard file.activities.contains(where: { $0.id == session.activityID }), session.windowID > 0,
                  session.processID > 0, session.launchedAt.timeIntervalSince1970.isFinite else { throw ActivityError.invalidData }
        }
    }
}
