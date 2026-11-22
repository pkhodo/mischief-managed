import Foundation
import Testing
@testable import FrameDeskCore

struct DesktopTilingTests {
    @Test func undoPreservesSpanningGeometryUntilDisplaysChange() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let displays = ["left": Box(left), "right": Box(right)]
        let spanning = CGRect(x: -300, y: 100, width: 900, height: 600)
        #expect(DesktopUndoGeometry.target(original: spanning, originalDisplays: displays, currentDisplays: displays, bounds: right) == spanning)
        let changed = ["right": Box(right)]
        let adjusted = DesktopUndoGeometry.target(original: spanning, originalDisplays: displays, currentDisplays: changed, bounds: right)
        #expect(right.contains(adjusted))
        #expect(adjusted != spanning)
    }

    @Test func allZonesFitAndHitTestOnUpperAndNegativeDisplays() {
        let bounds = [CGRect(x: -1920, y: -200, width: 1920, height: 1080), CGRect(x: 50, y: 1200, width: 2560, height: 1440)]
        for display in bounds {
            for preset in TilePreset.allCases.filter({ $0 != .freeform }) {
                let grid = TileGrid(preset: preset, columns: 6, rows: 4)
                let frames = grid.frames(in: display)
                #expect(!frames.isEmpty)
                for (i, frame) in frames.enumerated() {
                    #expect(display.contains(frame))
                    #expect(grid.zone(at: CGPoint(x: frame.midX, y: frame.midY), in: display) == i)
                    for other in frames.dropFirst(i+1) { #expect(!frame.intersects(other)) }
                }
                #expect(grid.zone(at: CGPoint(x: display.minX-1, y: display.midY), in: display) == nil)
            }
        }
    }
    @Test func perActivityAndDisplaySettingsSurviveRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DesktopTilingStore(url: dir.appendingPathComponent("desktop-tiling.json"))
        var file = try store.load(); file.enabled = true; file.showGrid = true; file.requireShift = true
        for i in 0..<15 {
            var profile = DesktopProfile(name: "Activity \(i)")
            profile.grids = ["left": TileGrid(preset: .focus, focusFraction: 0.6), "right": TileGrid(preset: .custom, columns: 3, rows: 2)]
            profile.windows = [Placement(bundleID: "test", appName: "Test", title: "A", ordinal: 0, displayID: "left", normalized: Box(CGRect(x: 0, y: 0, width: 0.5, height: 1)))]
            file.profiles["activity-\(i)"] = profile
        }
        file.activeScope = "activity-14"
        try store.save(file); #expect(try store.load() == file)
    }
    @Test func corruptFutureAndInvalidFilesCannotBeReplacedBySave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DesktopTilingStore(url: dir.appendingPathComponent("desktop-tiling.json"))
        let original = Data("unreadable".utf8); try original.write(to: store.url)
        #expect(throws: DecodingError.self) { try store.load() }
        var file = DesktopTilingFile(); file.version = 99
        #expect(throws: TilingError.self) { try store.save(file) }
        file.version = 1; file.profiles["desktop"]?.grids["display"] = TileGrid(columns: 0)
        #expect(throws: TilingError.self) { try store.save(file) }
        #expect(try Data(contentsOf: store.url) == original)
        let future = Data("{\"version\":99,\"enabled\":false,\"showGrid\":false,\"requireShift\":false,\"activeScope\":\"desktop\",\"profiles\":{}}".utf8)
        try future.write(to: store.url)
        #expect(throws: TilingError.self) { try store.load() }
        #expect(try Data(contentsOf: store.url) == future)
    }
}
