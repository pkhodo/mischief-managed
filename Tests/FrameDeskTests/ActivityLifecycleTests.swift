import Foundation
import Testing
import FrameDeskCore
@testable import FrameDesk

actor TestBrowser: ActivityBrowser {
    var windows: [Int: BrowserSnapshot] = [:]
    var opened = 0
    var closed: [Int] = []
    var focused: [Int] = []
    var allowClose = true
    var launchTime: TimeInterval = 100
    func open(activity: Activity, bounds: Box?) -> ActivityBrowserSession {
        opened += 1
        windows[opened] = BrowserSnapshot(websites: activity.websites, bounds: Box(CGRect(x: 10, y: 20, width: 600, height: 400)))
        return ActivityBrowserSession(activityID: activity.id, windowID: opened, processID: 42, launchedAt: Date(timeIntervalSince1970: launchTime))
    }
    private func verify(_ session: ActivityBrowserSession) throws {
        guard session.belongs(to: 42, launchedAt: Date(timeIntervalSince1970: launchTime)) else { throw BrowserError.expired }
        guard windows[session.windowID] != nil else { throw BrowserError.missing }
    }
    func snapshot(_ session: ActivityBrowserSession) throws -> BrowserSnapshot {
        try verify(session)
        let w = windows[session.windowID]!
        _ = try w.websites.map(WebsiteList.normalize)
        return w
    }
    func focus(_ session: ActivityBrowserSession) throws { try verify(session); focused.append(session.windowID) }
    func close(_ session: ActivityBrowserSession) -> Bool {
        guard allowClose else { return false }
        windows.removeValue(forKey: session.windowID); closed.append(session.windowID); return true
    }
    func setAllowClose(_ value: Bool) { allowClose = value }
    func setSites(_ id: Int, _ sites: [String]) { windows[id]?.websites = sites }
    func removeWindow(_ id: Int) { windows.removeValue(forKey: id) }
    func restart() { windows = [:]; launchTime += 1 }
}

@MainActor
struct ActivityLifecycleTests {
    @Test func returningToInternalTabDoesNotSerializeOrDuplicateIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let browser = TestBrowser(); let manager = ActivityManager(directory: dir, browser: browser)
        let a = Activity(name: "A", websites: ["https://example.com"])
        #expect(manager.save(a)); await manager.open(a.id)
        let session = try #require(manager.session(a.id))
        await browser.setSites(session.windowID, ["https://example.com", "edge://newtab/"])
        await manager.open(a.id)
        #expect(manager.error == nil)
        #expect(await browser.opened == 1)
        #expect(await browser.focused == [session.windowID])
        #expect(manager.session(a.id) == session)
        await manager.saveAndCloseWebsites(a.id)
        #expect(await browser.closed.isEmpty)
        #expect(manager.session(a.id) == session)
        #expect(manager.error?.contains("not a website address") == true)
    }
    @Test func missingAndExpiredWindowsRecoverWithoutClosingOtherSessions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let browser = TestBrowser(); let manager = ActivityManager(directory: dir, browser: browser)
        let a = Activity(name: "A", websites: ["https://example.com"])
        #expect(manager.save(a)); await manager.open(a.id)
        let first = try #require(manager.session(a.id))
        await browser.removeWindow(first.windowID)
        await manager.open(a.id)
        let second = try #require(manager.session(a.id))
        #expect(second.windowID != first.windowID)
        await browser.restart()
        await manager.open(a.id)
        let third = try #require(manager.session(a.id))
        #expect(third.launchedAt != second.launchedAt)
        #expect(await browser.opened == 3)
        #expect(await browser.closed.isEmpty)
        #expect(manager.error == nil)
    }
    @Test func switchingAndManagerRestartReuseOwnedWindows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let browser = TestBrowser(); let manager = ActivityManager(directory: dir, browser: browser)
        let a = Activity(name: "A", websites: ["https://example.com"])
        let b = Activity(name: "B", websites: ["https://example.org"])
        #expect(manager.save(a)); #expect(manager.save(b))
        await manager.open(a.id); await manager.open(b.id); await manager.open(a.id)
        #expect(await browser.opened == 2)
        #expect(await browser.closed.isEmpty)
        let restarted = ActivityManager(directory: dir, browser: browser)
        await restarted.open(a.id)
        #expect(await browser.opened == 2)
        #expect(restarted.session(a.id) == manager.session(a.id))
        let aid = try #require(restarted.session(a.id)?.windowID)
        let bid = try #require(restarted.session(b.id)?.windowID)
        await browser.setSites(aid, ["https://example.com/updated"])
        await restarted.saveAndCloseWebsites(a.id)
        #expect(restarted.session(a.id) == nil)
        #expect(restarted.session(b.id)?.windowID == bid)
        #expect(await browser.closed == [aid])
        #expect(restarted.activities.first(where: { $0.id == a.id })?.websites == ["https://example.com/updated"])
        await restarted.open(a.id)
        #expect(await browser.opened == 3)
    }
    @Test func pinnedAndCancelledClosureStayTracked() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let browser = TestBrowser(); let manager = ActivityManager(directory: dir, browser: browser)
        var a = Activity(name: "Pinned", websites: ["https://example.com"]); a.keepOpen = true
        #expect(manager.save(a)); await manager.open(a.id)
        await manager.saveAndCloseWebsites(a.id)
        #expect(await browser.closed.isEmpty)
        #expect(manager.session(a.id) != nil)
        manager.setKeepOpen(a.id, false); await browser.setAllowClose(false)
        await manager.saveAndCloseWebsites(a.id)
        #expect(manager.session(a.id) != nil)
        #expect(await browser.closed.isEmpty)
        #expect(manager.error?.contains("kept the window open") == true)
    }
    @Test func failedSaveNeverClosesWindow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let browser = TestBrowser(); let manager = ActivityManager(directory: dir, browser: browser)
        let a = Activity(name: "A", websites: ["https://example.com"])
        #expect(manager.save(a)); await manager.open(a.id)
        let url = dir.appendingPathComponent("activities.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        await manager.saveAndCloseWebsites(a.id)
        #expect(await browser.closed.isEmpty)
        #expect(manager.session(a.id) != nil)
        #expect(manager.error?.contains("Nothing will be closed") == true)
    }
    @Test func unownedOrEditedLiveActivityCannotLoseBrowserState() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let browser = TestBrowser(); let manager = ActivityManager(directory: dir, browser: browser)
        var a = Activity(name: "A", websites: ["https://example.com"])
        #expect(manager.save(a))
        await manager.saveAndCloseWebsites(a.id)
        #expect(await browser.closed.isEmpty)
        await manager.open(a.id)
        a.websites = ["https://example.org"]
        #expect(!manager.save(a))
        manager.delete(a.id)
        #expect(manager.activities.count == 1)
        #expect(await browser.closed.isEmpty)
    }
}
