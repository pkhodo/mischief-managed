import AppKit
import Foundation
import Testing
import FrameDeskCore
@testable import FrameDesk

private actor PausedBrowser: ActivityBrowser {
    private var waitingOpen: CheckedContinuation<Void,Never>?
    private var waitingClose: CheckedContinuation<Void,Never>?
    var opening = false
    var closing = false
    func open(activity:Activity,bounds:Box?) async -> ActivityBrowserSession {
        opening = true
        await withCheckedContinuation { waitingOpen = $0 }
        return ActivityBrowserSession(activityID:activity.id,windowID:1,processID:42,launchedAt:Date(timeIntervalSince1970:100))
    }
    func snapshot(_ session:ActivityBrowserSession) -> BrowserSnapshot {
        BrowserSnapshot(websites:["https://example.com/"],bounds:Box(CGRect(x:20,y:20,width:600,height:400)))
    }
    func focus(_ session:ActivityBrowserSession) {}
    func close(_ session:ActivityBrowserSession) async -> Bool {
        closing = true
        await withCheckedContinuation { waitingClose = $0 }
        return true
    }
    func releaseOpen() { waitingOpen?.resume(); waitingOpen=nil }
    func releaseClose() { waitingClose?.resume(); waitingClose=nil }
}

@MainActor
struct RestartSafetyTests {
    @Test func restartCannotInterruptActivityOwnership() async throws {
        _ = NSApplication.shared
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let state=AppState(directory:dir)
        let browser=PausedBrowser()
        let manager=ActivityManager(directory:dir,browser:browser)
        let activity=Activity(name:"Restart fixture",websites:["https://example.com/"])
        #expect(manager.save(activity))
        var launches=0
        let opening=Task { await manager.open(activity.id) }
        while !(await browser.opening) { await Task.yield() }
        #expect(manager.busy)
        state.restartForPermissions(activityManager:manager) { _ in launches += 1 }
        #expect(launches==0 && !state.restarting)
        await browser.releaseOpen(); await opening.value
        #expect(manager.session(activity.id) != nil)
        let closing=Task { await manager.saveAndCloseWebsites(activity.id) }
        while !(await browser.closing) { await Task.yield() }
        #expect(manager.busy)
        state.restartForPermissions(activityManager:manager) { _ in launches += 1 }
        #expect(launches==0 && !state.restarting)
        await browser.releaseClose(); await closing.value
        #expect(manager.session(activity.id)==nil)
    }

    @Test func restartSerializesAndLaunchFailureLeavesAppUsable() async {
        _ = NSApplication.shared
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let state=AppState(directory:dir),manager=ActivityManager(directory:dir,browser:PausedBrowser())
        var launches=0
        var completion:((Error?)->Void)?
        let launch: (@escaping (Error?)->Void)->Void = { callback in launches += 1; completion=callback }
        state.busy=true
        state.restartForPermissions(activityManager:manager,launch:launch)
        state.busy=false; state.capturing=true
        state.restartForPermissions(activityManager:manager,launch:launch)
        #expect(launches==0)
        state.capturing=false
        state.restartForPermissions(activityManager:manager,launch:launch)
        state.restartForPermissions(activityManager:manager,launch:launch)
        #expect(launches==1 && state.restarting)
        completion?(NSError(domain:"FrameDeskTest",code:1,userInfo:[NSLocalizedDescriptionKey:"Test launch failed"]))
        for _ in 0..<100 where state.restarting { await Task.yield() }
        #expect(!state.restarting)
        #expect(state.error?.contains("Test launch failed")==true)
        state.restartForPermissions(activityManager:manager,launch:launch)
        #expect(launches==2 && state.restarting)
        completion?(NSError(domain:"FrameDeskTest",code:2))
        for _ in 0..<100 where state.restarting { await Task.yield() }
        #expect(!state.restarting)
    }
}
