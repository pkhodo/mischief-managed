import SwiftUI
import AppKit
import FrameDeskCore

struct ActivityRootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var manager: ActivityManager
    @EnvironmentObject var tiling: DesktopTilingManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var phase
    @ViewState private var search = ""
    @ViewState private var sharing = false
    @ViewState private var editor: Activity?
    @ViewState private var deletion: Activity?
    @ViewState private var closing: Activity?
    @ViewState private var arrangement: WindowArrangementDraft?
    @ViewState private var tiles: ActivityTileDraft?
    @ViewState private var layoutDisplayID = ""

    private var filtered: [Activity] {
        manager.activities.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { a,b in
                if a.favorite != b.favorite { return a.favorite }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $manager.selectedID) {
                    Section("Activities") {
                        ForEach(filtered) { a in
                            HStack {
                                Image(systemName: a.favorite ? "star.fill" : "rectangle.3.group")
                                    .foregroundStyle(a.favorite ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(a.name).lineLimit(1)
                                    Text(manager.session(a.id) != nil ? (a.keepOpen ? "Keep open" : "Website window tracked") : "Saved setup")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.tag(a.id)
                        }
                    }
                }.searchable(text: $search, prompt: "Find an activity").disabled(tiles != nil)
                Divider()
                HStack {
                    Button { editor = Activity(name: "") } label: { Label("New activity", systemImage: "plus") }
                        .disabled(manager.busy || tiles != nil)
                    Spacer()
                }.padding(12)
            }.navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            if let activity = manager.activities.first(where: { $0.id == manager.selectedID }) {
                if let tiles, tiles.activityID == activity.id {
                    VStack(spacing: 0) {
                        Label("\(activity.name) · \(tiles.displayName)", systemImage: "display")
                            .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24).padding(.top, 16)
                        FreeformGridEditor(grid: tiles.grid, aspect: tiles.aspect, onSave: { grid in
                            guard tiling.displays.contains(where: { $0.id == tiles.displayID }) else { return false }
                            let saved = tiling.setGrid(grid, scope: activity.id.uuidString, name: activity.name,
                                                      display: tiles.displayID, context: tiles.context)
                            if saved { self.tiles = nil }
                            return saved
                        }, onCancel: { self.tiles = nil }).id(tiles.id)
                    }.background(Color(nsColor: .windowBackgroundColor))
                } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(activity.name).font(.largeTitle).fontWeight(.semibold).textSelection(.enabled)
                                Label(tiling.sceneStatus, systemImage: "display.2").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { manager.setFavorite(activity.id, !activity.favorite) } label: {
                                Image(systemName: activity.favorite ? "star.fill" : "star")
                            }.help(activity.favorite ? "Remove from favorites" : "Add to favorites")
                                .accessibilityLabel(activity.favorite ? "Remove favorite" : "Favorite activity")
                                .disabled(manager.busy)
                            Button("Edit") { editor = activity }.disabled(manager.busy)
                        }
                        HStack {
                            Button(manager.session(activity.id) == nil ? "Open activity" : "Return to activity") {
                                Task { await manager.open(activity.id, state: state) }
                            }.buttonStyle(.borderedProminent).disabled(manager.busy || state.busy)
                            if manager.session(activity.id) != nil {
                                Button("Save & close websites…") { closing = activity }
                                    .disabled(manager.busy || activity.keepOpen)
                            }
                            if manager.busy { ProgressView().controlSize(.small).accessibilityLabel("Updating activity") }
                        }
                        layoutOverview(activity)
                        if !activity.websites.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                Label("Websites in Microsoft Edge", systemImage: "globe").font(.headline)
                                Text("Opens a dedicated window in Edge’s current profile. Other activities and browser windows stay open.")
                                    .font(.callout).foregroundStyle(.secondary)
                                ForEach(Array(activity.websites.enumerated()), id: \.offset) { _, site in
                                    Text(site).lineLimit(2).textSelection(.enabled)
                                }
                                Toggle("Keep this website window open", isOn: Binding(get: { activity.keepOpen }, set: { manager.setKeepOpen(activity.id, $0) }))
                                    .disabled(manager.busy)
                                if activity.keepOpen { Text("Turn this off before using Save & close websites.").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if activity.area != nil {
                            Label("This activity remembers a sharing area", systemImage: "rectangle.dashed")
                            Button("Adjust or preview sharing area") { sharing = true }
                            Button("Update saved sharing area from current area") {
                                var updated = activity; updated.area = state.area; _ = manager.save(updated)
                            }.disabled(manager.busy)
                        }
                        if !manager.message.isEmpty {
                            Text(manager.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Button("Delete saved activity…", role: .destructive) { deletion = activity }
                            .disabled(manager.busy || manager.session(activity.id) != nil)
                    }.padding(28).frame(maxWidth: 780, alignment: .leading)
                }.background(Color(nsColor: .windowBackgroundColor))
                }
            } else {
                ContentUnavailableView {
                    Label(search.isEmpty ? "Your activities, ready when you are" : "No matching activity", systemImage: "rectangle.3.group")
                } description: {
                    Text(search.isEmpty ? "Create a setup for each kind of work. Save its websites and window arrangement, then return to it from here or the menu bar." : "Try another name or clear the search.")
                } actions: {
                    Button("Create an activity") { editor = Activity(name: "") }.disabled(manager.busy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .disabled(state.restarting)
        .toolbar {
            ToolbarItem { Button { tiling.editorScope = tiling.file.activeScope; openWindow(id: "desktop-tiling") } label: { Label("Desktop tiling", systemImage: "rectangle.split.2x2") } }
            ToolbarItem { Button { sharing = true } label: { Label("Sharing", systemImage: "rectangle.on.rectangle") }.disabled(manager.busy) }
            ToolbarItem { SettingsLink { Label("Settings", systemImage: "gearshape") }.help("Settings (⌘,)") }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = manager.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { manager.error = nil }
                }.padding().background(.regularMaterial)
            }
        }
        .sheet(item: $editor) { activity in ActivityEditor(activity: activity).environmentObject(manager).environmentObject(state) }
        .sheet(item: $arrangement) { draft in
            WindowArrangementEditor(draft: draft).environmentObject(tiling)
        }
        .onChange(of: manager.selectedID) { _, selection in
            if tiles?.activityID != selection { tiles = nil }
        }
        .sheet(isPresented: $sharing) { SharingSettingsView().environmentObject(state) }
        .confirmationDialog("Delete “\(deletion?.name ?? "")”?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("Delete saved setup", role: .destructive) { if let deletion { manager.delete(deletion.id) }; deletion = nil }
        } message: { Text("Only the saved setup is deleted. Your app windows and documents stay open.") }
        .confirmationDialog("Save & close this website window?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
            Button("Save & close websites") {
                if let closing { Task { await manager.saveAndCloseWebsites(closing.id) } }; closing = nil
            }
        } message: { Text("Saves this window’s current website addresses and position, then asks Edge to close it. Unsaved forms, page state and downloads are not saved. Other app and browser windows stay open.") }
        .onChange(of: phase) { _, value in if value == .active { manager.refreshBrowserLaunch(); state.refreshPermissions() } }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--activity-ui-snapshot") { tiling.refreshSceneDetection() }
            if ProcessInfo.processInfo.arguments.contains("--activity-ui-editor") { editor = Activity(name: "") }
            if ProcessInfo.processInfo.arguments.contains("--activity-ui-tiles"),
               let activity = manager.activities.first(where: { $0.id == manager.selectedID }), let display = tiling.displays.first {
                beginTileEdit(for: activity, display: display)
            }
            ActivityDiagnostics.runIfRequested(manager: manager, state: state)
        }
    }
    private func beginTileEdit(for activity: Activity, display: Display) {
        tiles = ActivityTileDraft(activityID: activity.id, displayID: display.id, displayName: tiling.displayLabel(display),
                                  grid: tiling.grid(scope: activity.id.uuidString, display: display.id), context: tiling.currentContext,
                                  aspect: display.visible.width / max(1, display.visible.height))
    }
    private func layoutOverview(_ activity: Activity) -> some View {
        let display = tiling.displays.first { $0.id == layoutDisplayID } ?? tiling.displays.first
        let scope = activity.id.uuidString
        let windows = tiling.savedWindows(for: activity)
        let showLayout = !tiling.hasDisplayScenes || tiling.currentContext != .unassigned
        let shownWindows = windows.filter { $0.displayID == display?.id || $0.displayID == display.map { tiling.displayKey($0.id) } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Window layout").font(.headline)
                Spacer()
                if tiling.displays.count > 1 {
                    Picker("Display", selection: Binding(get: { display?.id ?? "" }, set: { layoutDisplayID = $0 })) {
                        ForEach(tiling.displays) { Text(tiling.displayLabel($0)).tag($0.id) }
                    }.fixedSize()
                }
                SettingsLink { Text("Display settings…") }
            }
            if let display, showLayout {
                let grid = tiling.grid(scope: scope, display: display.id)
                TileGridPreview(grid: grid, windows: shownWindows)
                    .aspectRatio(display.visible.width / max(1, display.visible.height), contentMode: .fit)
                    .frame(maxHeight: 240)
                Text(shownWindows.isEmpty ? "No saved windows on this display" : "\(shownWindows.count) saved window\(shownWindows.count == 1 ? "" : "s") on this display")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Edit tiles") {
                        beginTileEdit(for: activity, display: display)
                    }.disabled(!tiling.canSaveArrangement || manager.busy)
                    Button("Save window arrangement…") {
                        arrangement = WindowArrangementDraft(activity: activity, context: tiling.currentContext,
                                                             configuration: Display.all.map(DisplayConfiguration.init))
                    }.disabled(!tiling.canSaveArrangement || !state.accessibilityAllowed || manager.busy)
                }
                HStack(spacing: 18) {
                    Toggle("Show guides", isOn: Binding(get: { tiling.showGrid }, set: { tiling.setShowGrid($0) }))
                        .help("Keep subtle, click-through tile outlines on the desktop")
                }
                Text(tiling.file.activeScope == scope ? "Drag a window to snap. Hold Option to place it freely." : "Open this activity to use its tiles and guides.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(display == nil ? "Connect a display to see its layout." : "Choose or register a matching display scene to use its saved layout.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !state.accessibilityAllowed {
                SettingsLink { Text("Enable Accessibility to save and restore windows") }
            }
            if let error = tiling.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
            }
        }
    }
}

private struct ActivityTileDraft: Identifiable {
    let id = UUID()
    let activityID: UUID
    let displayID: String
    let displayName: String
    let grid: TileGrid
    let context: SceneContext
    let aspect: CGFloat
}

private struct WindowArrangementDraft: Identifiable {
    let id = UUID()
    let activity: Activity
    let context: SceneContext
    let configuration: [DisplayConfiguration]
}

private struct WindowArrangementEditor: View {
    @EnvironmentObject var tiling: DesktopTilingManager
    @Environment(\.dismiss) private var dismiss
    let draft: WindowArrangementDraft
    @ViewState private var windows: [LiveWindow] = []
    @ViewState private var selected: Set<UUID> = []
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save window arrangement").font(.title2)
            Text("Choose the windows to remember for \(draft.activity.name). Saving keeps their current positions.")
                .foregroundStyle(.secondary)
            List(windows) { window in
                Toggle(window.label, isOn: Binding(get: { selected.contains(window.id) }, set: { value in
                    if value { selected.insert(window.id) } else { selected.remove(window.id) }
                }))
            }.overlay {
                if windows.isEmpty { Text("No visible windows found").foregroundStyle(.secondary) }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
            HStack {
                Button("Refresh windows") { refresh() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save arrangement") {
                    if tiling.saveArrangement(windows.filter { selected.contains($0.id) }, for: draft.activity,
                                              context: draft.context, configuration: draft.configuration) {
                        dismiss()
                    } else { error = tiling.error }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
            }
        }.padding(24).frame(width: 600, height: 420).onAppear { refresh() }
    }
    private func refresh() {
        do {
            let saved = windows.isEmpty ? tiling.savedWindows(for: draft.activity) : windows.filter { selected.contains($0.id) }.map(\.placement)
            windows = try WindowManager.scan()
            let matches = WindowMatching.match(saved: saved, live: windows.map(\.placement))
            selected = Set(matches.map { windows[$0.live].id })
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct ActivityEditor: View {
    @EnvironmentObject var manager: ActivityManager
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft: Activity
    @ViewState private var sites: String
    @ViewState private var candidates: [LiveWindow] = []
    @ViewState private var selected: Set<UUID> = []
    @ViewState private var choseWindows = false
    @ViewState private var rememberArea: Bool
    @ViewState private var localError: String?
    @ViewState private var arrangement = ActivityArrangement.current
    init(activity: Activity) {
        _draft = ViewState(initialValue: activity)
        _sites = ViewState(initialValue: activity.websites.joined(separator: "\n"))
        _rememberArea = ViewState(initialValue: activity.area != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(manager.activities.contains(where: { $0.id == draft.id }) ? "Edit activity" : "New activity").font(.title2)
            Form {
                TextField("Activity name", text: $draft.name, prompt: Text("For example, Annual report"))
                Section("Websites · one address per line") {
                    TextEditor(text: $sites).font(.body).frame(height: 105).accessibilityLabel("Website addresses, one per line")
                        .disabled(manager.session(draft.id) != nil)
                    Text(manager.session(draft.id) != nil ? "Save & close the website window before editing this list." : "Uses Microsoft Edge’s current profile. Normal http and https addresses are supported; Edge Workspaces are not connected yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if state.tiling.usesOriginalArrangement(for: draft) {
                Section("Original window arrangement") {
                    Picker("Arrange selected windows", selection: $arrangement) {
                        ForEach(ActivityArrangement.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                    }.pickerStyle(.segmented)
                    Button(choseWindows ? "Refresh open windows" : "Choose open windows…") { loadWindows() }
                    if choseWindows {
                        List(candidates) { window in
                            Toggle(window.label, isOn: Binding(get: { selected.contains(window.id) }, set: {
                                if $0 { selected.insert(window.id) } else { selected.remove(window.id) }
                            }))
                        }.frame(height: 140)
                        Text("\(selected.count) selected. Only these windows will belong to the saved arrangement.").font(.caption)
                    } else { Text("\(draft.windows.count) windows saved. Keep them, or choose a different set.").font(.callout).foregroundStyle(.secondary) }
                    Text("The saved arrangement is applied when you open the activity. Some apps need larger windows.").font(.caption).foregroundStyle(.secondary)
                }
                }
                Toggle("Remember the current sharing area", isOn: $rememberArea)
                Toggle("Favorite activity", isOn: $draft.favorite)
            }.formStyle(.grouped)
            if let localError { Text(localError).foregroundStyle(.primary).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save activity") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(manager.busy || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 640, height: choseWindows ? 680 : 530).background(Color(nsColor: .windowBackgroundColor))
    }
    private func loadWindows() {
        do {
            candidates = try WindowManager.scan()
            let matches = WindowMatching.match(saved: draft.windows, live: candidates.map(\.placement))
            selected = Set(matches.map { candidates[$0.live].id }); choseWindows = true; localError = nil
        } catch { localError = error.localizedDescription }
    }
    private func save() {
        do {
            draft.websites = try WebsiteList.parse(sites)
            if choseWindows { draft.windows = candidates.filter { selected.contains($0.id) }.map(\.placement) }
            if arrangement != .current {
                for group in Dictionary(grouping: draft.windows.indices, by: { draft.windows[$0].displayID }).values {
                    guard let first = group.first, let display = state.displays.first(where: { $0.id == draft.windows[first].displayID }) ?? state.display else { continue }
                    let boxes = arrangement.frames(count: group.count, in: display.visible)
                    for (i,index) in group.enumerated() {
                        draft.windows[index].displayID = display.id
                        draft.windows[index].normalized = Geometry.normalized(boxes[i], in: display.visible)
                    }
                }
            }
            draft.area = rememberArea ? (draft.area ?? state.area) : nil
            if manager.save(draft) { dismiss() } else { localError = manager.error }
        } catch { localError = error.localizedDescription }
    }
}

struct SharingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Sharing").font(.title2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
            ControlView(showLegacyLayouts: false, showPermissions: false)
            HStack {
                Text("Mischief Managed \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · activities preview").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Native Edge Workspaces: not connected").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }.frame(width: 680, height: 780).background(Color(nsColor: .windowBackgroundColor))
    }
}
