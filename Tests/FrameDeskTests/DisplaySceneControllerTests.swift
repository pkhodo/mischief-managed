import AppKit
import Testing
import FrameDeskCore
@testable import FrameDesk

@MainActor
struct DisplaySceneControllerTests {
    @Test func workAreaNotificationsKeepSnappingAndTopologyChangesPauseIt() throws {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let manager=DesktopTilingManager(directory:directory)
        let before=manager.file
        manager.screensChanged()
        #expect(!manager.detectingScene)
        var changed=Display.all.map(DisplayConfiguration.init)
        #expect(!changed.isEmpty)
        guard !changed.isEmpty else { return }
        changed[0].visible.width-=1
        manager.screensChanged(snapshot: changed)
        #expect(!manager.detectingScene)
        changed[0].frame.width -= 1
        manager.screensChanged(snapshot: changed)
        #expect(manager.detectingScene)
        #expect(manager.file==before)
        manager.stop()
        #expect(!manager.detectingScene)
    }
    @Test func detectedContextsKeepActivityGridsIndependentAndRejectRedirectedDraft() throws {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let manager=DesktopTilingManager(directory:directory)
        let home=SceneDisplay(id:"home",name:"Home 32"),left=SceneDisplay(id:"left",name:"Work left"),right=SceneDisplay(id:"right",name:"Work right")
        manager.refreshSceneDetection(snapshot:[home])
        #expect(manager.saveScene(DisplayScene(name:" Home ",required:["home"])))
        let originalContext=manager.currentContext
        #expect(manager.currentSceneName=="Home")
        #expect(manager.setGrid(TileGrid(preset:.focus),scope:"writing",name:"Writing",display:"home",context:originalContext))
        manager.refreshSceneDetection(snapshot:[left,right])
        #expect(manager.currentContext == .unassigned)
        #expect(manager.saveScene(DisplayScene(name:"Work",required:["left","right"])))
        #expect(manager.setGrid(TileGrid(preset:.thirds),scope:"writing",name:"Writing",display:"left"))
        #expect(!manager.setGrid(TileGrid(preset:.halves),scope:"writing",name:"Writing",display:"home",context:originalContext))
        #expect(manager.grid(scope:"writing",display:"left").preset == .thirds)
        manager.refreshSceneDetection(snapshot:[home])
        #expect(manager.grid(scope:"writing",display:"home").preset == .focus)
        let reloaded=DesktopTilingManager(directory:directory)
        reloaded.refreshSceneDetection(snapshot:[home])
        #expect(reloaded.currentContext==originalContext)
        #expect(reloaded.grid(scope:"writing",display:"home").preset == .focus)
        #expect(reloaded.file.scenes?.autoRestore==false)
    }
    @Test func persistedAliasCollisionCannotOpenRegistrationAndCanBeSeparated() throws {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let first=SceneDisplay(id:"original",name:"Original monitor"),other=SceneDisplay(id:"reconnected",name:"Reconnected monitor")
        let manager=DesktopTilingManager(directory:directory)
        manager.refreshSceneDetection(snapshot:[first])
        #expect(manager.saveScene(DisplayScene(name:"Home",required:[first.id])))
        manager.refreshSceneDetection(snapshot:[other])
        #expect(manager.mapDisplay(other.id,to:first.id))
        let reloaded=DesktopTilingManager(directory:directory)
        reloaded.refreshSceneDetection(snapshot:[first,other])
        #expect(reloaded.sceneResolution == .unknown)
        let library=try #require(reloaded.file.scenes)
        let before=try Data(contentsOf:reloaded.store.url)
        let newDraft=SceneEditorDraft(scene:nil,connected:reloaded.sceneDisplays,library:library,suggested:"Work")
        let editDraft=SceneEditorDraft(scene:library.scenes[0],connected:reloaded.sceneDisplays,library:library,suggested:"Home")
        #expect(newDraft?.id == nil && editDraft?.id == nil)
        #expect(try Data(contentsOf:reloaded.store.url)==before)
        #expect(reloaded.removeDisplayAlias(other.id))
        let separated=try #require(reloaded.file.scenes)
        #expect(separated.scenes==library.scenes)
        #expect(separated.aliases[other.id]==nil)
        let recovered=SceneEditorDraft(scene:separated.scenes[0],connected:reloaded.sceneDisplays,library:separated,suggested:"Home")
        #expect(recovered?.displays.count==2)
        let fromDisk=DesktopTilingManager(directory:directory)
        #expect(fromDisk.file.scenes?.aliases[other.id]==nil)
    }
    @Test func explicitAliasRestoresIdentityButRejectsDuplicateConnectedRole() throws {
        _=NSApplication.shared
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let manager=DesktopTilingManager(directory:directory)
        let first=SceneDisplay(id:"old",name:"My display"),new=SceneDisplay(id:"new",name:"My display")
        manager.refreshSceneDetection(snapshot:[first])
        #expect(manager.saveScene(DisplayScene(name:"Home",required:["old"])))
        manager.refreshSceneDetection(snapshot:[new])
        #expect(manager.currentContext == .unassigned)
        #expect(manager.mapDisplay("new",to:"old"))
        #expect(manager.currentSceneName=="Home" && manager.displayKey("new")=="old")
        manager.refreshSceneDetection(snapshot:[first,SceneDisplay(id:"other",name:"Other")])
        #expect(!manager.mapDisplay("other",to:"old"))
        #expect(manager.file.scenes?.aliases["other"]==nil)
    }
}
