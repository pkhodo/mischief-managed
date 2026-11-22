import AppKit
import Foundation
import Testing
import FrameDeskCore
@testable import FrameDesk

@MainActor
struct DesktopTilingSafetyTests {
    @Test func unreadableSettingsAreNeverOverwrittenByUIActions() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("desktop-tiling.json")
        let bytes = Data("corrupt tiling settings".utf8); try bytes.write(to: url)
        let manager = DesktopTilingManager(directory: directory)
        #expect(manager.error != nil)
        manager.setEnabled(true)
        manager.setShowGrid(true)
        manager.activate(scope: "test", name: "Test")
        manager.setGrid(TileGrid(preset: .thirds), scope: "test", name: "Test", display: "display")
        #expect(try Data(contentsOf: url) == bytes)
        #expect(!manager.enabled && !manager.showGrid && manager.file.profiles["test"] == nil)
    }
    @Test func changingOneActivityGridDoesNotChangeAnotherOrMoveWindows() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = DesktopTilingManager(directory: directory)
        manager.setGrid(TileGrid(preset: .focus), scope: "a", name: "Activity A", display: "display")
        manager.setGrid(TileGrid(preset: .thirds), scope: "b", name: "Activity B", display: "display")
        manager.activate(scope: "a", name: "Activity A", restore: false)
        #expect(manager.grid(display: "display").preset == .focus)
        manager.activate(scope: "b", name: "Activity B", restore: false)
        #expect(manager.grid(display: "display").preset == .thirds)
        #expect(manager.file.profiles.values.allSatisfy { $0.windows.isEmpty })
        let reloaded = DesktopTilingManager(directory: directory)
        #expect(reloaded.file == manager.file)
        #expect(!manager.canUndo && !reloaded.canUndo)
        let old = manager.file
        manager.setGrid(TileGrid(columns: 99), scope: "b", name: "Activity B", display: "display")
        #expect(manager.file == old)
    }
}
