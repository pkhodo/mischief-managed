import Foundation
import Testing
@testable import FrameDeskCore

struct DisplaySceneTests {
    let home=SceneDisplay(id:"home",name:"Home 32",main:true)
    let left=SceneDisplay(id:"left",name:"Work monitor")
    let right=SceneDisplay(id:"right",name:"Work monitor")
    let laptop=SceneDisplay(id:"laptop",name:"Laptop",builtIn:true)
    let ipad=SceneDisplay(id:"ipad",name:"My iPad")
    func library()->DisplaySceneLibrary {
        var library=DisplaySceneLibrary()
        library.knownDisplays=Dictionary(uniqueKeysWithValues:[home,left,right,laptop,ipad].map { ($0.id,$0) })
        library.scenes=[DisplayScene(name:"Home",required:["home"],optional:["ipad"]),DisplayScene(name:"Work",required:["left","right"],optional:["ipad"]),DisplayScene(name:"Laptop only",required:[],optional:["ipad"],requireBuiltIn:true)]
        return library
    }
    @Test func recognizesRequiredOptionalBuiltinAndUnknownDisplays() {
        let library=library()
        for (screens,index) in [([home],0),([home,ipad,laptop],0),([left,right],1),([left,right,laptop],1),([laptop],2),([laptop,ipad],2)] {
            guard case .recognized(let context)=library.resolve(screens) else { Issue.record("Known setup not recognized");continue }
            #expect(context.sceneID==library.scenes[index].id)
        }
        #expect(library.resolve([left]) == .unknown)
        #expect(library.resolve([home,SceneDisplay(id:"unknown",name:"iPad")]) == .unknown)
        #expect(library.resolve([]) == .unknown)
    }
    @Test func ambiguousScenesRequireExplicitPreferenceAndAliasNeverGuessesByName() {
        var library=library()
        library.scenes.append(DisplayScene(name:"Another Home",required:["home"],optional:["ipad"]))
        guard case .ambiguous(let candidates)=library.resolve([home]) else { Issue.record("Expected ambiguity");return }
        #expect(candidates.count==2)
        library.preferences[DisplaySceneLibrary.token([home])]=library.scenes[0].id
        #expect(library.resolve([home]) == .recognized(SceneContext(sceneID:library.scenes[0].id,variant:DisplaySceneLibrary.token([home]))))
        library.scenes.removeLast() // Alias behavior is independent of the deliberate ambiguity above.
        let newIpad=SceneDisplay(id:"ipad-new",name:"My iPad")
        #expect(library.resolve([home,newIpad]) == .unknown)
        library.aliases["ipad-new"]="ipad"
        guard case .recognized(let context)=library.resolve([home,newIpad]) else { Issue.record("Explicit alias not recognized");return }
        #expect(context.sceneID==library.scenes[0].id)
        #expect(library.resolve([home,newIpad,ipad]) == .unknown)
    }
    @Test func sameActivityWindowKeepsIndependentHomeWorkAndOptionalVariants() throws {
        var file=DesktopTilingFile();file.scenes=library()
        func context(_ screens:[SceneDisplay])->SceneContext {
            guard case .recognized(let value)=file.scenes!.resolve(screens) else { fatalError("Fixture scene missing") };return value
        }
        let h=context([home]),w=context([left,right]),open=context([left,right,laptop])
        file.scenes?.ensureVariant(h,connected:[home]);file.scenes?.ensureVariant(w,connected:[left,right])
        let id=UUID()
        var profile=DesktopProfile(name:"Writing")
        profile.grids["home"]=TileGrid(preset:.focus)
        var placement=Placement(bundleID:"test",appName:"Test",title:"Same document",ordinal:0,displayID:"home",normalized:Box(CGRect(x:0,y:0,width:0.6,height:1)))
        placement.id=id;profile.windows=[placement]
        let savedHome=file.setProfile(profile,scope:"writing",context:h);#expect(savedHome)
        var atWork=DesktopProfile(name:"Writing");atWork.grids["left"]=TileGrid(preset:.thirds)
        placement.displayID="left";placement.normalized=Box(CGRect(x:0.5,y:0,width:0.5,height:1));atWork.windows=[placement]
        let savedWork=file.setProfile(atWork,scope:"writing",context:w);#expect(savedWork)
        #expect(file.profile(scope:"writing",context:h)==profile)
        file.scenes?.ensureVariant(open,connected:[left,right,laptop])
        #expect(file.profile(scope:"writing",context:open)==atWork)
        var withLaptop=atWork;withLaptop.windows[0].displayID="laptop"
        let savedLaptop=file.setProfile(withLaptop,scope:"writing",context:open);#expect(savedLaptop)
        #expect(file.profile(scope:"writing",context:w)==atWork)
        #expect(file.profile(scope:"writing",context:h)==profile)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=DesktopTilingStore(url:directory.appendingPathComponent("tiling.json"));try store.save(file)
        #expect(try store.load()==file)
    }
    @Test func newOptionalVariantNeverRehomesMissingDisplayWindows() {
        var library=library()
        guard case .recognized(let open)=library.resolve([left,right,laptop]),case .recognized(let closed)=library.resolve([left,right]) else { Issue.record("Missing fixtures");return }
        library.ensureVariant(open,connected:[left,right,laptop])
        var profile=DesktopProfile(name:"Writing")
        profile.windows=[Placement(bundleID:"test",appName:"Test",title:"Draft",ordinal:0,displayID:"laptop",normalized:Box(CGRect(x:0,y:0,width:1,height:1)))]
        let saved=library.setProfile(profile,scope:"writing",context:open);#expect(saved)
        library.ensureVariant(closed,connected:[left,right])
        #expect(library.profile(scope:"writing",context:closed)?.windows.isEmpty==true)
        #expect(library.profile(scope:"writing",context:open)==profile)
    }
    @Test func newVariantInheritsEachActivityFromItsOwnNearestVariant() {
        var library=library()
        guard case .recognized(let closed)=library.resolve([home]),
              case .recognized(let withLaptop)=library.resolve([home,laptop]),
              case .recognized(let withBoth)=library.resolve([home,laptop,ipad]) else { Issue.record("Missing fixtures");return }
        library.ensureVariant(closed,connected:[home])
        var writing=DesktopProfile(name:"Writing");writing.grids["home"]=TileGrid(preset:.focus)
        let savedWriting=library.setProfile(writing,scope:"writing",context:closed);#expect(savedWriting)
        library.ensureVariant(withLaptop,connected:[home,laptop])
        // The laptop variant has only been used for Coding.
        library.scenes[0].variants[withLaptop.variant]?.profiles.removeValue(forKey:"writing")
        var coding=DesktopProfile(name:"Coding");coding.grids["home"]=TileGrid(preset:.thirds)
        let savedCoding=library.setProfile(coding,scope:"coding",context:withLaptop);#expect(savedCoding)
        library.ensureVariant(withBoth,connected:[home,laptop,ipad])
        #expect(library.profile(scope:"writing",context:withBoth)==writing)
        #expect(library.profile(scope:"coding",context:withBoth)==coding)
        #expect(library.profile(scope:"writing",context:closed)==writing)
    }
    @Test func legacyDataSurvivesRegistrationAndInvalidSceneCannotOverwriteIt() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=DesktopTilingStore(url:directory.appendingPathComponent("tiling.json"))
        var old=DesktopTilingFile();old.profiles["desktop"]?.grids["home"]=TileGrid(preset:.quarters)
        try store.save(old);let legacyBytes=try Data(contentsOf:store.url)
        #expect(try store.load().scenes==nil)
        var next=old;next.scenes=DisplaySceneLibrary()
        let scene=DisplayScene(name:"Home",required:["home"],optional:["ipad"])
        next.scenes?.knownDisplays["ipad"]=ipad
        next.scenes?.register(scene,connected:[home],legacy:old.profiles)
        #expect(next.profiles==old.profiles)
        guard case .recognized(let context)=next.scenes!.resolve([home]) else { Issue.record("Registration missing");return }
        #expect(next.profile(scope:"desktop",context:context)==old.profiles["desktop"])
        try store.save(next)
        let registered=try Data(contentsOf:store.url)
        next.scenes?.aliases["bogus"]="not-known"
        #expect(throws:TilingError.self) { try store.save(next) }
        #expect(try Data(contentsOf:store.url)==registered)
        #expect(legacyBytes != registered)
    }
}
