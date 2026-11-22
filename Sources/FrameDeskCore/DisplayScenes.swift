import Foundation
import CoreGraphics

public struct SceneDisplay: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var builtIn: Bool
    public var main: Bool
    public var frame: Box
    public init(id: String, name: String, builtIn: Bool = false, main: Bool = false, frame: Box = Box(CGRect(x:0,y:0,width:1920,height:1080))) {
        self.id=id;self.name=name;self.builtIn=builtIn;self.main=main;self.frame=frame
    }
}

public struct SceneContext: Equatable, Hashable, Sendable {
    public var sceneID: UUID?
    public var variant: String
    public init(sceneID:UUID? = nil,variant:String = "") { self.sceneID=sceneID;self.variant=variant }
    public static let unassigned=SceneContext()
    public var key: String { (sceneID?.uuidString ?? "unassigned")+":"+variant }
}

public enum SceneResolution: Equatable, Sendable {
    case unconfigured, unknown, ambiguous([UUID]), recognized(SceneContext)
}

public struct SceneVariant: Codable, Equatable, Sendable {
    public var displays:[SceneDisplay]
    public var profiles:[String:DesktopProfile]
    public init(displays:[SceneDisplay],profiles:[String:DesktopProfile]=[:]) { self.displays=displays;self.profiles=profiles }
}

public struct DisplayScene: Codable, Equatable, Sendable, Identifiable {
    public var id:UUID
    public var name:String
    public var required:Set<String>
    public var optional:Set<String>
    public var allowBuiltIn:Bool
    public var requireBuiltIn:Bool
    public var variants:[String:SceneVariant] = [:]
    public init(id:UUID=UUID(),name:String,required:Set<String>,optional:Set<String>=[],allowBuiltIn:Bool=true,requireBuiltIn:Bool=false) {
        self.id=id;self.name=name;self.required=required;self.optional=optional;self.allowBuiltIn=allowBuiltIn;self.requireBuiltIn=requireBuiltIn
    }
}

public struct DisplaySceneLibrary: Codable, Equatable, Sendable {
    public var scenes:[DisplayScene]=[]
    public var knownDisplays:[String:SceneDisplay]=[:]
    public var aliases:[String:String]=[:]
    public var preferences:[String:UUID]=[:]
    public var autoRestore=false
    public init() {}
    public func canonicalID(_ id:String)->String { aliases[id] ?? id }
    public func canonical(_ displays:[SceneDisplay])->[SceneDisplay] {
        displays.map { value in var result=value;result.id=canonicalID(value.id);return result }
    }
    public static func token(_ displays:[SceneDisplay])->String {
        displays.map(\.id).sorted().map { "\($0.utf8.count):\($0)" }.joined()
    }
    public func resolve(_ connected:[SceneDisplay])->SceneResolution {
        guard !scenes.isEmpty else { return .unconfigured }
        let displays=canonical(connected)
        guard !displays.isEmpty,Set(displays.map(\.id)).count==displays.count else { return .unknown }
        let external=Set(displays.filter { !$0.builtIn }.map(\.id))
        let hasBuiltIn=displays.contains { $0.builtIn }
        let matches=scenes.filter { scene in
            scene.required.isSubset(of:external)
            && external.isSubset(of:scene.required.union(scene.optional))
            && (!hasBuiltIn || scene.allowBuiltIn)
            && (!scene.requireBuiltIn || hasBuiltIn)
        }
        let token=Self.token(displays)
        if let preferred=preferences[token],matches.contains(where: { $0.id==preferred }) { return .recognized(SceneContext(sceneID:preferred,variant:token)) }
        let specificity=matches.map { $0.required.count*2+($0.requireBuiltIn ? 1 : 0) }.max()
        let best=matches.filter { $0.required.count*2+($0.requireBuiltIn ? 1 : 0)==specificity }
        guard best.count==1,let scene=best.first else { return best.isEmpty ? .unknown : .ambiguous(best.map(\.id)) }
        return .recognized(SceneContext(sceneID:scene.id,variant:token))
    }
    public mutating func register(_ scene:DisplayScene,connected:[SceneDisplay],legacy:[String:DesktopProfile]) {
        let displays=canonical(connected)
        for display in displays {
            if knownDisplays[display.id]==nil { knownDisplays[display.id]=display }
        }
        if let index=scenes.firstIndex(where: { $0.id==scene.id }) {
            var updated=scene;updated.variants=scenes[index].variants;scenes[index]=updated
        } else { scenes.append(scene) }
        // This explicit registration chooses a matching scene, never an unknown one.
        let check=DisplaySceneLibrary.matches(scene:scene,displays:displays)
        if check {
            let context=SceneContext(sceneID:scene.id,variant:Self.token(displays))
            preferences[context.variant]=scene.id
            ensureVariant(context,connected:connected,legacy:legacy)
        }
    }
    private static func matches(scene:DisplayScene,displays:[SceneDisplay])->Bool {
        let external=Set(displays.filter { !$0.builtIn }.map(\.id))
        return !displays.isEmpty && scene.required.isSubset(of:external) && external.isSubset(of:scene.required.union(scene.optional))
        && (!displays.contains { $0.builtIn } || scene.allowBuiltIn) && (!scene.requireBuiltIn || displays.contains { $0.builtIn })
    }
    public mutating func ensureVariant(_ context:SceneContext,connected:[SceneDisplay],legacy:[String:DesktopProfile]?=nil) {
        guard let index=scenes.firstIndex(where: { $0.id==context.sceneID }),scenes[index].variants[context.variant]==nil else { return }
        let displays=canonical(connected),ids=Set(displays.map(\.id))
        for display in displays where display.builtIn && knownDisplays[display.id]==nil { knownDisplays[display.id]=display }
        let candidates=scenes[index].variants.sorted { $0.key < $1.key }
        // Choose the nearest variant separately for each activity. A variant that has
        // never used Writing must not erase Writing's starting layout from this scene.
        let scopes=Set(candidates.flatMap { $0.value.profiles.keys })
        var source:[String:DesktopProfile]=[:]
        for scope in scopes {
            source[scope]=candidates.filter { $0.value.profiles[scope] != nil }.max { a,b in
                Set(a.value.displays.map(\.id)).intersection(ids).count < Set(b.value.displays.map(\.id)).intersection(ids).count
            }?.value.profiles[scope]
        }
        // Legacy import occurs only on explicit registration of a scene's first variant.
        if candidates.isEmpty { source=legacy ?? [:] }
        var profiles:[String:DesktopProfile]=[:]
        for (scope,profile) in source {
            var copy=DesktopProfile(name:profile.name)
            copy.capturedArrangement=profile.capturedArrangement
            for (id,grid) in profile.grids where ids.contains(canonicalID(id)) { copy.grids[canonicalID(id)]=grid }
            copy.windows=profile.windows.compactMap { placement in
                var copy=placement;copy.displayID=canonicalID(copy.displayID)
                return ids.contains(copy.displayID) ? copy : nil
            }
            profiles[scope]=copy
        }
        scenes[index].variants[context.variant]=SceneVariant(displays:displays,profiles:profiles)
    }
    public func profile(scope:String,context:SceneContext)->DesktopProfile? {
        scenes.first { $0.id==context.sceneID }?.variants[context.variant]?.profiles[scope]
    }
    @discardableResult
    public mutating func setProfile(_ profile:DesktopProfile,scope:String,context:SceneContext)->Bool {
        guard let index=scenes.firstIndex(where: { $0.id==context.sceneID }),scenes[index].variants[context.variant] != nil else { return false }
        scenes[index].variants[context.variant]?.profiles[scope]=profile;return true
    }
    public var isValid:Bool {
        let ids=Set(scenes.map(\.id))
        guard scenes.count<=100,ids.count==scenes.count,
              Set(scenes.map { $0.name.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() }).count==scenes.count,
              knownDisplays.allSatisfy({ !$0.key.isEmpty && $0.key==$0.value.id && !$0.value.name.isEmpty && $0.value.frame.isValid }),
              aliases.allSatisfy({ !$0.key.isEmpty && $0.key != $0.value && knownDisplays[$0.value] != nil && knownDisplays[$0.key]==nil }),
              preferences.allSatisfy({ !$0.key.isEmpty && ids.contains($0.value) }) else { return false }
        return scenes.allSatisfy { scene in
            !scene.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && (!scene.required.isEmpty || scene.requireBuiltIn)
            && (!scene.requireBuiltIn || scene.allowBuiltIn) && scene.required.isDisjoint(with:scene.optional)
            && scene.required.union(scene.optional).allSatisfy { knownDisplays[$0] != nil && knownDisplays[$0]?.builtIn==false }
            && scene.variants.count<=100 && scene.variants.allSatisfy { key,variant in
                !key.isEmpty && key==Self.token(variant.displays) && Set(variant.displays.map(\.id)).count==variant.displays.count
                && variant.displays.allSatisfy { knownDisplays[$0.id] != nil && $0.frame.isValid }
                && variant.profiles.count<=1000
                && variant.profiles.allSatisfy { _,profile in
                    let connected=Set(variant.displays.map(\.id))
                    return profile.isValid && Set(profile.grids.keys).isSubset(of:connected) && profile.windows.allSatisfy { connected.contains($0.displayID) }
                }
            }
        }
    }
}

extension DesktopProfile {
    public var isValid:Bool {
        !name.isEmpty && grids.values.allSatisfy(\.isValid) && Set(windows.map(\.id)).count==windows.count
        && windows.allSatisfy { p in
            let r=p.normalized
            return r.isValid && !p.displayID.isEmpty && !p.bundleID.isEmpty && r.x >= -0.001 && r.y >= -0.001 && r.x+r.width<=1.001 && r.y+r.height<=1.001
        }
    }
}

extension DesktopTilingFile {
    public func profile(scope:String,context:SceneContext)->DesktopProfile? {
        if context.sceneID != nil { return scenes?.profile(scope:scope,context:context) }
        return profiles[scope]
    }
    @discardableResult
    public mutating func setProfile(_ profile:DesktopProfile,scope:String,context:SceneContext)->Bool {
        if profiles[scope]==nil { profiles[scope]=DesktopProfile(name:profile.name) }
        if context.sceneID != nil { return scenes?.setProfile(profile,scope:scope,context:context) ?? false }
        profiles[scope]=profile;return true
    }
}
