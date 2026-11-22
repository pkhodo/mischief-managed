import Foundation
import Testing
@testable import FrameDeskCore

struct WorkspaceTests {
    @Test func coordinatesRoundTripAcrossLeftAndUpperDisplays() {
        for frame in [CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: 0, y: 1080, width: 1600, height: 900)] {
            let rect = CGRect(x: frame.minX+80, y: frame.minY+100, width: 600, height: 400)
            #expect(Geometry.expanded(Geometry.normalized(rect, in: frame), in: frame) == rect)
            #expect(Geometry.flipped(Geometry.flipped(rect, primaryTop: 1080), primaryTop: 1080) == rect)
            #expect(Geometry.sourceRect(rect, display: frame) == CGRect(x: 80, y: frame.height-500, width: 600, height: 400))
        }
    }
    @Test func outputRespectsScaleAnd1080pLimit() {
        #expect(Geometry.outputSize(region: CGSize(width: 960, height: 540), scale: 2) == CGSize(width: 1920, height: 1080))
        #expect(Geometry.outputSize(region: CGSize(width: 1920, height: 1080), scale: 2) == CGSize(width: 1920, height: 1080))
        #expect(Geometry.outputSize(region: CGSize(width: 500, height: 500), scale: 2) == CGSize(width: 1000, height: 1000))
    }
    @Test func regionCannotEscapeDisplayOrBecomeNegative() {
        let visible = CGRect(x: -1800, y: 24, width: 1800, height: 1000)
        let rect = Geometry.clamped(CGRect(x: -2500, y: -100, width: 4000, height: 2000), in: visible)
        #expect(rect == visible)
        #expect(visible.contains(Geometry.clamped(CGRect(x: 0, y: 0, width: -2, height: -10), in: visible)))
    }
    @Test func tilesStayInsideCaptureAreaAndDoNotOverlap() {
        let region = CGRect(x: -900, y: 500, width: 960, height: 540)
        for count in 1...12 {
            let tiles = Geometry.tiles(count: count, in: region)
            #expect(tiles.count == count)
            for (i,tile) in tiles.enumerated() {
                #expect(region.contains(tile))
                for other in tiles.dropFirst(i+1) { #expect(!tile.intersects(other)) }
            }
        }
    }
    private func placement(_ title: String, ordinal: Int = 0) -> Placement {
        Placement(bundleID: "test.editor", appName: "Test", title: title, ordinal: ordinal, displayID: "screen", normalized: Box(CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
    }
    @Test func matchingRestoresTitlesAfterWindowOrderChanges() {
        let saved = [placement("A"), placement("B", ordinal: 1)]
        let live = [placement("B"), placement("A", ordinal: 1)]
        let matches = WindowMatching.match(saved: saved, live: live)
        #expect(matches.map(\.live) == [1,0])
    }
    @Test func changedSingleTitleFallsBackButAmbiguousWindowsAreSkipped() {
        #expect(WindowMatching.match(saved: [placement("Old")], live: [placement("New")]).count == 1)
        #expect(WindowMatching.match(saved: [placement("Old"),placement("Other", ordinal: 1)], live: [placement("New"),placement("Different", ordinal: 1)]).isEmpty)
        #expect(WindowMatching.match(saved: [placement("A"),placement("A", ordinal: 1)], live: [placement("A"),placement("A", ordinal: 1)]).isEmpty)
        #expect(WindowMatching.match(saved: [placement("A", ordinal: 1)], live: [placement("A"),placement("A", ordinal: 1)]).isEmpty)
    }
    @Test func saveLoadAndCorruptionDoesNotOverwriteSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(url: directory.appendingPathComponent("workspaces.json"))
        #expect(try store.load().layouts.isEmpty)
        var file = WorkspaceFile()
        file.layouts = [Workspace(name: "Meeting", windows: [placement("Test")], area: SavedArea(displayID: "screen", normalized: Box(CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))))]
        try store.save(file)
        #expect(try store.load() == file)
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: store.url)
        #expect(throws: DecodingError.self) { try store.load() }
        #expect(try Data(contentsOf: store.url) == corrupt)
    }
    @Test func unsupportedVersionIsRejectedAndRetained() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("workspaces.json")
        let bytes = Data("{\"version\":99,\"layouts\":[]}".utf8)
        try bytes.write(to: url)
        #expect(throws: WorkspaceStore.StoreError.self) { try WorkspaceStore(url: url).load() }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
