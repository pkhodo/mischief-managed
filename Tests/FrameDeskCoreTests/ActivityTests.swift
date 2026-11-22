import Foundation
import Testing
@testable import FrameDeskCore

struct ActivityTests {
    @Test func activityTemplatesStayOnDisplay() {
        let display = CGRect(x: -1920, y: 60, width: 1920, height: 1000)
        for kind in [ActivityArrangement.columns, .grid] {
            for count in 1...25 {
                let frames = kind.frames(count: count, in: display)
                #expect(frames.count == count)
                for (i,frame) in frames.enumerated() {
                    #expect(display.contains(frame))
                    for other in frames.dropFirst(i+1) { #expect(!frame.intersects(other)) }
                }
            }
        }
    }
    @Test func websiteValidationPreservesOrderAndRejectsCommands() throws {
        #expect(try WebsiteList.parse("example.com\nhttps://example.org/path?q=one\n\nhttp://localhost:8080") == ["https://example.com", "https://example.org/path?q=one", "http://localhost:8080"])
        for input in ["javascript:alert(1)", "file:///tmp/a", "https://user:password@example.com", "https://", "a b.com", "edge://workspaces"] {
            #expect(throws: ActivityError.self) { try WebsiteList.normalize(input) }
        }
    }
    @Test func legacyImportKeepsIdentityAndNeverReimportsOverExistingActivities() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(url: directory.appendingPathComponent("activities.json"))
        let legacy = Workspace(name: "Existing", windows: [], area: nil)
        var file = try store.load(legacy: [legacy])
        #expect(file.activities.first?.id == legacy.id)
        file.activities = []
        try store.save(file)
        #expect(try store.load(legacy: [legacy]).activities.isEmpty)
    }
    @Test func manyActivitiesAndIndependentSessionsRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityStore(url: directory.appendingPathComponent("activities.json"))
        var file = ActivityFile()
        file.activities = (1...25).map { Activity(name: "Activity \($0)", websites: ["https://example.com/\($0)"]) }
        let date = Date(timeIntervalSince1970: 100)
        file.sessions = [ActivityBrowserSession(activityID: file.activities[0].id, windowID: 10, processID: 42, launchedAt: date), ActivityBrowserSession(activityID: file.activities[1].id, windowID: 11, processID: 42, launchedAt: date)]
        try store.save(file)
        #expect(try store.load() == file)
        #expect(file.sessions[0].belongs(to: 42, launchedAt: date))
        #expect(!file.sessions[0].belongs(to: 43, launchedAt: date))
        #expect(!file.sessions[0].belongs(to: 42, launchedAt: date.addingTimeInterval(1)))
    }
    @Test func corruptOrFutureDataAndDuplicateOwnershipCannotBeOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ActivityStore(url: directory.appendingPathComponent("activities.json"))
        let future = Data("{\"version\":99,\"activities\":[],\"sessions\":[]}".utf8)
        try future.write(to: store.url)
        #expect(throws: ActivityError.self) { try store.load() }
        #expect(try Data(contentsOf: store.url) == future)
        var file = ActivityFile(); let a = Activity(name: "A"); file.activities = [a, a]
        #expect(throws: ActivityError.self) { try store.save(file) }
        #expect(try Data(contentsOf: store.url) == future)
        try Data("broken".utf8).write(to: store.url)
        #expect(throws: DecodingError.self) { try store.load() }
        #expect(try Data(contentsOf: store.url) == Data("broken".utf8))
    }
}
