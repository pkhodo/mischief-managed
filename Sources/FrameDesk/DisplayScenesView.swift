import SwiftUI
import FrameDeskCore

struct DisplayScenesView: View {
    @EnvironmentObject var tiling:DesktopTilingManager
    @EnvironmentObject var state:AppState
    var embedded = false
    @ViewState private var editor:SceneEditorDraft?
    @ViewState private var aliasDisplay:SceneDisplay?
    @ViewState private var aliasTarget=""
    @ViewState private var identityHelp = false
    private var library:DisplaySceneLibrary { tiling.file.scenes ?? DisplaySceneLibrary() }
    var body: some View {
        Group {
            if embedded { sceneControls }
            else { ScrollView { sceneControls.padding(26) }.frame(minWidth: 650, minHeight: 600) }
        }
        .disabled(state.restarting)
        .onAppear {
            tiling.startIfInteractive()
            tiling.refreshSceneDetection()
            if ProcessInfo.processInfo.arguments.contains("--edit-scene") { beginEdit(nil) }
        }
    }
    private var sceneControls: some View {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment:.leading,spacing:6) {
                    Text("Display setups").font(.title2).fontWeight(.semibold)
                    Text("Remember separate layouts for different monitor setups.").foregroundStyle(.secondary)
                }
                Label(tiling.sceneStatus,systemImage:"display.2").font(.headline).accessibilityAddTraits(.updatesFrequently)
                if tiling.hasDisplayScenes {
                    Toggle("Restore the active layout when displays change", isOn: Binding(get: { library.autoRestore }, set: { tiling.setAutomaticSceneRestore($0) }))
                }
                if let editor {
                    SceneRegistrationEditor(draft:editor,onSave:{ scene,labels in
                        guard Set(editor.rawDisplayIDs)==Set(tiling.sceneDisplays.map(\.id)),!tiling.detectingScene else { return false }
                        let saved=tiling.saveScene(scene,labels:labels)
                        if saved { self.editor=nil };return saved
                    },onCancel:{ self.editor=nil }).id(editor.id)
                } else {
                    HStack {
                        Text("Connected displays").font(.headline)
                        Spacer()
                        Button("Save this display setup…") { beginEdit(nil) }.disabled(tiling.detectingScene || tiling.sceneDisplays.isEmpty)
                    }
                    ForEach(tiling.sceneDisplays) { display in
                        HStack {
                            Text(library.knownDisplays[tiling.displayKey(display.id)]?.name ?? display.name)
                            Spacer()
                            Text(display.positionHint(relativeTo: tiling.sceneDisplays.first(where: \.main)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if tiling.sceneDisplays.contains(where: { library.aliases[$0.id] != nil || !identityOptions(for: $0).isEmpty }) {
                        DisclosureGroup("Display identity help", isExpanded: $identityHelp) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(tiling.sceneDisplays) { display in
                                    if library.aliases[display.id] != nil {
                                        Button("Use \(display.name) as a separate display") { tiling.removeDisplayAlias(display.id) }
                                    } else if !identityOptions(for: display).isEmpty {
                                        Button("Identify \(display.name)…") {
                                            aliasDisplay = display
                                            aliasTarget = identityOptions(for: display).first?.id ?? ""
                                        }
                                    }
                                }
                                if let display = aliasDisplay {
                                    Text("Choose the saved name for this same physical display.").foregroundStyle(.secondary)
                                    Picker("Saved display", selection: $aliasTarget) {
                                        ForEach(identityOptions(for: display)) { option in Text(option.name).tag(option.id) }
                                    }
                                    HStack {
                                        Button("Cancel") { aliasDisplay = nil }
                                        Button("Remember this identity") {
                                            if tiling.mapDisplay(display.id, to: aliasTarget) { aliasDisplay = nil }
                                        }.disabled(!identityOptions(for: display).contains(where: { $0.id == aliasTarget }))
                                    }
                                }
                            }.padding(.top, 6)
                        }
                    }
                    if !library.scenes.isEmpty { Divider(); Text("Saved display setups").font(.headline) }
                    ForEach(library.scenes) { scene in
                        VStack(alignment:.leading,spacing:8) {
                            HStack {
                                Text(scene.name).font(.headline)
                                if scene.id==tiling.currentContext.sceneID { Text("Detected").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Button("Edit") { beginEdit(scene) }
                                if scene.id != tiling.currentContext.sceneID && canUse(scene.id) && !tiling.detectingScene {
                                    Button("Use scene") { tiling.chooseScene(scene.id) }
                                }
                            }
                            Text(description(scene)).font(.callout).foregroundStyle(.secondary)
                        }.padding(.vertical,4)
                    }
                }
                if let error=tiling.error {
                    HStack(alignment:.top) {
                        Label(error,systemImage:"exclamationmark.triangle").textSelection(.enabled)
                        Spacer();Button("Dismiss") { tiling.error=nil }
                    }
                }
            }
    }
    private func identityOptions(for display: SceneDisplay) -> [SceneDisplay] {
        guard library.knownDisplays[tiling.displayKey(display.id)] == nil else { return [] }
        let activeIDs = Set(tiling.sceneDisplays.map { tiling.displayKey($0.id) })
        return library.knownDisplays.values.filter { $0.builtIn == display.builtIn && !activeIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func beginEdit(_ scene:DisplayScene?) {
        let existing=Set(library.scenes.map(\.name))
        let suggested=tiling.sceneDisplays.allSatisfy(\.builtIn) ? "Laptop only" : !existing.contains("Home") ? "Home" : !existing.contains("Work") ? "Work" : "New scene"
        guard let draft=SceneEditorDraft(scene:scene,connected:tiling.sceneDisplays,library:library,suggested:suggested) else {
            identityHelp = true
            tiling.error = "Two connected displays use the same saved identity. Choose a separate identity under Display identity help, then try again."
            return
        }
        editor=draft
    }
    private func canUse(_ id:UUID)->Bool {
        var copy=library;copy.preferences[DisplaySceneLibrary.token(copy.canonical(tiling.sceneDisplays))]=id
        if case .recognized(let context)=copy.resolve(tiling.sceneDisplays) { return context.sceneID==id };return false
    }
    private func description(_ scene:DisplayScene)->String {
        let required=scene.required.sorted().compactMap { library.knownDisplays[$0]?.name }
        let optional=scene.optional.sorted().compactMap { library.knownDisplays[$0]?.name }
        return "Required: "+(required+(scene.requireBuiltIn ? ["laptop screen"] : [])).joined(separator:", ")
        + (optional.isEmpty ? "" : " · Optional: "+optional.joined(separator:", "))
        + (scene.allowBuiltIn && !scene.requireBuiltIn ? " · Laptop screen optional" : "")
    }
}

struct SceneEditorDraft:Identifiable {
    let id=UUID()
    let scene:DisplayScene
    let displays:[SceneDisplay]
    let rawDisplayIDs:[String]
    let connectedIDs:Set<String>
    let mainDisplay:SceneDisplay?
    init?(scene:DisplayScene?,connected:[SceneDisplay],library:DisplaySceneLibrary,suggested:String) {
        let canonical=library.canonical(connected)
        guard Set(canonical.map(\.id)).count==canonical.count else { return nil }
        mainDisplay=canonical.first(where: \.main)
        rawDisplayIDs=connected.map(\.id);connectedIDs=Set(canonical.map(\.id))
        let external=canonical.filter { !$0.builtIn }.map { value -> SceneDisplay in
            var copy=value;copy.name=library.knownDisplays[value.id]?.name ?? value.name;return copy
        }
        self.scene=scene ?? DisplayScene(name:suggested,required:Set(external.map(\.id)),requireBuiltIn:external.isEmpty)
        var records=Dictionary(uniqueKeysWithValues:external.map { ($0.id,$0) })
        for id in (scene?.required ?? []).union(scene?.optional ?? []) {
            if records[id]==nil { records[id]=library.knownDisplays[id] }
        }
        displays=records.values.sorted { $0.id < $1.id }
    }
}

struct SceneRegistrationEditor:View {
    let draft:SceneEditorDraft
    let onSave:(DisplayScene,[String:String])->Bool
    let onCancel:()->Void
    @ViewState private var name:String
    @ViewState private var included:Set<String>
    @ViewState private var required:Set<String>
    @ViewState private var labels:[String:String]
    @ViewState private var allowBuiltIn:Bool
    @ViewState private var requireBuiltIn:Bool
    @ViewState private var error=""
    private enum Role: String, CaseIterable {
        case required = "Required", optional = "Optional", excluded = "Excluded"
    }
    init(draft:SceneEditorDraft,onSave:@escaping(DisplayScene,[String:String])->Bool,onCancel:@escaping()->Void) {
        self.draft=draft;self.onSave=onSave;self.onCancel=onCancel
        _name=ViewState(initialValue:draft.scene.name);_included=ViewState(initialValue:draft.scene.required.union(draft.scene.optional))
        _required=ViewState(initialValue:draft.scene.required);_labels=ViewState(initialValue:Dictionary(uniqueKeysWithValues:draft.displays.map { ($0.id,$0.name) }))
        _allowBuiltIn=ViewState(initialValue:draft.scene.allowBuiltIn);_requireBuiltIn=ViewState(initialValue:draft.scene.requireBuiltIn)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Save display setup").font(.title2)
            TextField("Setup name",text:$name)
            DisclosureGroup("Customize displays") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("An optional display can come and go. Each combination keeps its own layout.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(draft.displays) { display in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Display name", text: Binding(get: { labels[display.id] ?? display.name }, set: { labels[display.id] = $0 }))
                                    .accessibilityLabel("Name for \(display.name)")
                                Text(draft.connectedIDs.contains(display.id) ? display.positionHint(relativeTo: draft.mainDisplay) : "Disconnected")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Picker("Role for \(display.name)", selection: Binding(get: {
                                required.contains(display.id) ? Role.required : included.contains(display.id) ? .optional : .excluded
                            }, set: { role in
                                if role == .required { required.insert(display.id) } else { required.remove(display.id) }
                                if role == .excluded { included.remove(display.id) } else { included.insert(display.id) }
                            })) {
                                ForEach(Role.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                    }
                    Picker("Laptop screen", selection: Binding(get: {
                        requireBuiltIn ? Role.required : allowBuiltIn ? .optional : .excluded
                    }, set: { role in
                        allowBuiltIn = role != .excluded
                        requireBuiltIn = role == .required
                    })) {
                        ForEach(Role.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }.padding(.top, 6)
            }
            if required.isEmpty && !requireBuiltIn { Text("Choose a required display, or require the laptop screen.").font(.callout).foregroundStyle(.secondary) }
            if !error.isEmpty { Text(error).textSelection(.enabled) }
            HStack {
                Button("Cancel",action:onCancel)
                Spacer()
                Button("Save setup") {
                    var scene=draft.scene;scene.name=name.trimmingCharacters(in:.whitespacesAndNewlines)
                    scene.required=required;scene.optional=included.subtracting(required);scene.allowBuiltIn=allowBuiltIn;scene.requireBuiltIn=requireBuiltIn
                    if !onSave(scene,labels) { error="Could not save. The displays may have changed; your draft is kept. Check the error below, or cancel and review the connected setup." }
                }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (required.isEmpty && !requireBuiltIn))
            }
        }
    }
}

private extension SceneDisplay {
    func positionHint(relativeTo mainDisplay:SceneDisplay?)->String {
        if main { return "Main display" }
        guard let mainDisplay else { return "Connected display" }
        let dx=frame.rect.midX-mainDisplay.frame.rect.midX
        let dy=frame.rect.midY-mainDisplay.frame.rect.midY
        if abs(dx)>abs(dy) { return dx<0 ? "Left of main display" : "Right of main display" }
        if abs(dy)>1 { return dy>0 ? "Above main display" : "Below main display" }
        return "Aligned with main display"
    }
}
