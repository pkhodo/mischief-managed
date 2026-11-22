import SwiftUI
import FrameDeskCore

struct DesktopTilingView: View {
    @EnvironmentObject var tiling: DesktopTilingManager
    @EnvironmentObject var activities: ActivityManager
    @EnvironmentObject var state: AppState
    @ViewState private var displayID = ""
    @ViewState private var draft: GridDraft?
    private struct GridDraft: Identifiable {
        let id=UUID()
        let scope: String
        let name: String
        let displayID: String
        let displayName: String
        let aspect: CGFloat
        let grid: TileGrid
        let scene: SceneContext
    }
    private var scope: String { tiling.editorScope }
    private var name: String { scope == "desktop" ? "Desktop" : activities.activities.first { $0.id.uuidString == scope }?.name ?? tiling.file.profiles[scope]?.name ?? "Activity" }
    private var display: Display? { tiling.displays.first { $0.id == displayID } ?? tiling.displays.first }
    private var grid: TileGrid { tiling.grid(scope: scope, display: display?.id ?? "") }
    private var scopes: [(String, String)] {
        var values = [("desktop", "Desktop")]
        values += activities.activities.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { ($0.id.uuidString, $0.name) }
        if !values.contains(where: { $0.0 == scope }) { values.append((scope, name)) }
        return values
    }
    var body: some View {
        Group {
            if let draft {
                VStack(spacing: 0) {
                    Text("\(draft.name) · \(draft.displayName)").font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 16)
                    FreeformGridEditor(grid: draft.grid, aspect: draft.aspect, onSave: { config in
                        guard tiling.displays.contains(where: { $0.id == draft.displayID }) else { return false }
                        let saved = tiling.setGrid(config, scope: draft.scope, name: draft.name, display: draft.displayID, context: draft.scene)
                        if saved { self.draft = nil }
                        return saved
                    }, onCancel: { self.draft = nil }).id(draft.id)
                }
            } else {
                options
            }
        }
        .frame(minWidth: 600, minHeight: 650)
        .disabled(state.restarting)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            tiling.startIfInteractive()
            if displayID.isEmpty { displayID = display?.id ?? "" }; state.refreshPermissions();tiling.refreshSceneDetection()
            if ProcessInfo.processInfo.arguments.contains("--edit-tiles") && draft == nil { beginEditing() }
        }
        .onChange(of: tiling.displays.map(\.id)) { _, ids in if !ids.contains(displayID) { displayID = ids.first ?? "" } }
    }
    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Desktop tiling").font(.largeTitle).fontWeight(.semibold)
                    Text("Choose a layout for snapping windows.").foregroundStyle(.secondary)
                }
                HStack {
                    Toggle("Show grid", isOn: Binding(get: { tiling.showGrid }, set: { tiling.setShowGrid($0) })).toggleStyle(.switch)
                }
                if !state.accessibilityAllowed {
                    HStack {
                        Label("Accessibility access is needed to move windows.", systemImage: "hand.raised")
                        Spacer()
                        SettingsLink { Text("Open Settings") }
                    }
                }
                HStack {
                    Label(tiling.sceneStatus,systemImage:"display.2").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    SettingsLink { Text("Display settings…") }
                }
                Divider()
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Setup").font(.headline)
                        Picker("Setup", selection: $tiling.editorScope) {
                            ForEach(scopes, id: \.0) { Text($0.1).tag($0.0) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Display").font(.headline)
                        Picker("Display", selection: $displayID) {
                            ForEach(tiling.displays) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Grid").font(.headline)
                    Picker("Grid preset", selection: Binding(get: { grid.preset }, set: { value in
                        var config = grid
                        if value == .freeform && config.customZones == nil { config=config.asFreeform() }
                        config.preset=value;save(config)
                    })) {
                        ForEach(TilePreset.allCases, id: \.self) { Text($0 == .custom ? "Equal grid" : $0 == .freeform ? "Draw your own" : $0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    if grid.preset == .custom {
                        HStack(spacing: 30) {
                            Stepper("\(grid.columns) columns", value: Binding(get: { grid.columns }, set: { var config = grid; config.columns = $0; save(config) }), in: 1...6)
                            Stepper("\(grid.rows) rows", value: Binding(get: { grid.rows }, set: { var config = grid; config.rows = $0; save(config) }), in: 1...4)
                        }
                    }
                    if grid.preset == .focus {
                        HStack {
                            Text("Main tile: \(Int(grid.focusFraction*100))%")
                            Slider(value: Binding(get: { grid.focusFraction }, set: { var config = grid; config.focusFraction = $0; save(config) }), in: 0.3...0.8, step: 0.05)
                                .accessibilityLabel("Main tile width")
                        }
                    }
                    TileGridPreview(grid: grid).frame(height: 190)
                    Button("Edit tiles…") { beginEditing() }.buttonStyle(.borderedProminent)
                        .help("Draw, move and resize individual tiles with unequal sizes")
                    HStack {
                        Text(tiling.file.activeScope == scope ? "Active grid · \(tiling.activeName)" : "Currently using \(tiling.activeName)’s grid")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Use this grid") { tiling.activate(scope: scope, name: name) }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Place the focused window").font(.headline)
                    Text("Focus an app window, then choose a tile here or in the menu bar. Only that window moves.")
                        .font(.callout).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(grid.zones.indices, id: \.self) { index in
                            Button("Tile \(index+1)") {
                                if tiling.file.activeScope != scope { tiling.activate(scope: scope, name: name, restore: false) }
                                if let display { tiling.placeFrontmost(in: index, displayID: display.id) }
                            }.disabled(!state.accessibilityAllowed || display == nil)
                                .accessibilityLabel("Place focused window in tile \(index+1)")
                        }
                    }
                }
                Divider()
                Text("Drag a window to snap. Hold Option to place it freely.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(tiling.status).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Undo tiling") { tiling.undoLastMove() }.disabled(!tiling.canUndo)
                }
                if let error = tiling.error {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { tiling.error = nil }
                    }
                }
            }.padding(26).frame(maxWidth: 760, alignment: .leading)
        }
    }
    private func beginEditing() {
        guard let display else { return }
        draft=GridDraft(scope:scope,name:name,displayID:display.id,displayName:display.name,aspect:display.visible.width/display.visible.height,grid:grid,scene:tiling.currentContext)
    }
    private func save(_ config: TileGrid) {
        guard let display else { return }
        tiling.setGrid(config, scope: scope, name: name, display: display.id)
    }
}

struct TileGridPreview: View {
    let grid: TileGrid
    var windows: [Placement] = []
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                ForEach(Array(grid.zones.enumerated()), id: \.offset) { i, box in
                    let r = box.rect
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.08)))
                        .overlay {
                            if windows.isEmpty { Text("\(i+1)").font(.headline).foregroundStyle(.primary) }
                        }
                        .frame(width: max(1, r.width*proxy.size.width-8), height: max(1, r.height*proxy.size.height-8))
                        .position(x: r.midX*proxy.size.width, y: (1-r.midY)*proxy.size.height)
                }
                ForEach(windows) { window in
                    let r = Geometry.clamped(window.normalized.rect, in: CGRect(x: 0, y: 0, width: 1, height: 1),
                                             minimum: CGSize(width: 0.02, height: 0.02))
                    RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.20))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.55)))
                        .overlay { Text(window.appName).font(.caption).lineLimit(1).padding(4) }
                        .frame(width: r.width * proxy.size.width, height: r.height * proxy.size.height)
                        .clipped()
                        .position(x: r.midX * proxy.size.width, y: (1 - r.midY) * proxy.size.height)
                }
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(windows.isEmpty ? (grid.preset == .freeform ? "Freeform grid, \(grid.zones.count) individually positioned tiles" : "\(grid.preset.rawValue) grid, \(grid.zones.count) tiles numbered left to right, top to bottom") : "Saved windows: " + windows.map(\.appName).joined(separator: ", "))
    }
}
