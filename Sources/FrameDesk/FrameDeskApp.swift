import SwiftUI
import AppKit
import FrameDeskCore

// Keep the property-wrapper API available on macOS 14; newer SDKs also export a
// same-named State macro whose plugin is not included in command-line-only tools.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct FrameDeskApp: App {
    @StateObject private var state = AppState()
    @StateObject private var activities = ActivityManager()
    init() { AppIcons.installDockIcon() }
    var body: some Scene {
        Window("Mischief Managed", id: "workspace") {
            Group {
                if ProcessInfo.processInfo.arguments.contains("--scenes-ui-snapshot") {
                    DisplayScenesView().onAppear { TilingDiagnostics.snapshotIfRequested() }
                } else if ProcessInfo.processInfo.arguments.contains("--tiling-ui-snapshot") {
                    DesktopTilingView().onAppear { TilingDiagnostics.snapshotIfRequested() }
                } else if ProcessInfo.processInfo.arguments.contains("--permissions-ui-snapshot") {
                    PermissionSettingsView()
                        .onAppear { ActivityDiagnostics.runIfRequested(manager: activities, state: state) }
                } else if ProcessInfo.processInfo.arguments.contains("--integration-check") || ProcessInfo.processInfo.arguments.contains("--ui-snapshot") {
                    ControlView()
                } else {
                    ActivityRootView().environmentObject(activities)
                }
            }.environmentObject(state).environmentObject(activities).environmentObject(state.tiling)
                .onAppear { state.tiling.startIfInteractive() }
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--activity-ui-snapshot") || ProcessInfo.processInfo.arguments.contains("--permissions-ui-snapshot") ? (ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : .light) : nil)
        }
        .defaultSize(width: ProcessInfo.processInfo.arguments.contains("--tiling-ui-snapshot") ? 680 : ProcessInfo.processInfo.arguments.contains("--permissions-ui-snapshot") ? 640 : 980,
                     height: ProcessInfo.processInfo.arguments.contains("--permissions-ui-snapshot") ? 780 : 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Show Preview Window") { state.capture.showPreview(region: state.region) }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Restore Previous Arrangement") { state.restorePrevious() }
                    .keyboardShortcut("z", modifiers: [.command, .option]).disabled(!state.canUndo)
            }
        }
        Window("Arrange windows", id: "desktop-tiling") {
            DesktopTilingView().environmentObject(state).environmentObject(activities).environmentObject(state.tiling)
        }.defaultSize(width: 680, height: 850).windowResizability(.contentMinSize)
        Settings {
            PermissionSettingsView().environmentObject(state).environmentObject(activities)
        }
        MenuBarExtra {
            MenuContents().environmentObject(state).environmentObject(activities).environmentObject(state.tiling).disabled(state.restarting)
        } label: {
            Image(nsImage: AppIcons.menuBar(capturing: state.capturing))
                .accessibilityLabel(state.capturing ? "Mischief Managed, capture active" : "Mischief Managed")
                .help(state.capturing ? "Mischief Managed — capture active" : "Mischief Managed")
        }
    }
}

struct MenuContents: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var activities: ActivityManager
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var tiling: DesktopTilingManager
    var body: some View {
        Button("Open Mischief Managed") { openWindow(id: "workspace"); NSApp.activate(ignoringOtherApps: true) }
        Button("Arrange windows…") { tiling.editorScope = tiling.file.activeScope; openWindow(id: "desktop-tiling"); NSApp.activate(ignoringOtherApps: true) }
        Toggle("Show desktop grid", isOn: Binding(get: { tiling.showGrid }, set: { tiling.setShowGrid($0) }))
        Menu("Place focused window") {
            ForEach(Array(tiling.displays.enumerated()), id: \.element.id) { index, display in
                Menu(tiling.displays.filter { $0.name == display.name }.count > 1 ? "\(display.name) · Display \(index+1)" : display.name) {
                    ForEach(tiling.grid(display: display.id).zones.indices, id: \.self) { zone in
                        Button("Tile \(zone+1)") { tiling.placeFrontmost(in: zone, displayID: display.id) }
                    }
                }
            }
        }.disabled(!state.accessibilityAllowed)
        Button("Undo tiling") { tiling.undoLastMove() }.disabled(!tiling.canUndo)
        Divider()
        Button(state.capturing ? "Stop Preview" : "Start Preview") { state.capturing ? state.stopCapture() : state.startCapture() }.disabled(state.busy)
        Button(state.editing ? "Lock Capture Area" : "Adjust Capture Area") { state.toggleEditing() }.disabled(state.busy)
        Button("Show Preview Window") { state.capture.showPreview(region: state.region) }
        SettingsLink { Text("Settings…") }
        Divider()
        if !activities.activities.isEmpty {
            Menu("Open Activity") {
                ForEach(activities.activities.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { activity in
                    Button(activity.name) { Task { await activities.open(activity.id, state: state) } }
                        .disabled(activities.busy || state.busy)
                }
            }
        }
        if !state.layouts.isEmpty {
            Menu("Restore Layout") { ForEach(state.layouts) { layout in Button(layout.name) { state.restore(layout) } } }
        }
        Button("Restore Previous Arrangement") { state.restorePrevious() }.disabled(!state.canUndo)
        Divider()
        Button("Quit Mischief Managed") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct ControlView: View {
    var showLegacyLayouts = true
    var showPermissions = true
    @EnvironmentObject var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ViewState private var deletion: Workspace?
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Display", selection: Binding(get: { state.displayID }, set: { state.chooseDisplay($0) })) {
                        ForEach(state.displays) { display in Text(display.name).tag(display.id) }
                    }.disabled(state.busy)
                    LabeledContent("Quarter-screen preset") {
                        HStack {
                            ForEach(0..<4) { corner in
                                Button(["Top left", "Top right", "Bottom left", "Bottom right"][corner]) { state.resetArea(corner: corner) }
                                    .disabled(state.busy)
                            }
                        }
                    }
                    GeometryEditor().disabled(state.busy)
                    HStack {
                        Button(state.editing ? "Lock area" : "Move or resize area") { state.toggleEditing() }
                            .disabled(state.busy)
                        Spacer()
                        Text(state.outputLabel).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(state.editing ? "Drag the area or its edges. Press Escape to lock it. The preview pauses while you adjust." : "The locked boundary lets clicks pass through to the windows underneath.")
                        .font(.callout).foregroundStyle(.secondary)
                } header: { Text("Capture area") }

                Section {
                    HStack {
                        Button(state.capturing ? "Stop preview" : "Start preview") { state.capturing ? state.stopCapture() : state.startCapture() }
                            .buttonStyle(.borderedProminent).disabled(state.busy || state.displays.isEmpty)
                        if state.busy { ProgressView().controlSize(.small).accessibilityLabel("Updating capture") }
                        Button("Show preview window") { state.capture.showPreview(region: state.region) }
                        Spacer()
                    }
                    Text("In Meet or Teams, choose Window and select “Mischief Managed — Share this window”. Move the preview wherever you like; it does not move the capture area.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } header: { Text("Meeting preview") }

                if showLegacyLayouts { Section {
                    HStack {
                        TextField("Layout name", text: $state.layoutName).onSubmit { state.saveLayout() }
                        Button("Save current layout") { state.saveLayout() }
                            .disabled(!state.accessibilityAllowed || state.layoutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if state.layouts.isEmpty {
                        Text("Arrange your windows, name the layout, then save. The current capture area is saved with it.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(state.layouts) { layout in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(layout.name).lineLimit(1).help(layout.name)
                                    Text("\(layout.windows.count) windows").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Restore") { state.restore(layout) }.disabled(!state.accessibilityAllowed || state.busy)
                                    .accessibilityLabel("Restore \(layout.name)")
                                Button { deletion = layout } label: { Image(systemName: "trash") }
                                    .accessibilityLabel("Delete saved layout \(layout.name)").help("Delete saved layout")
                            }
                        }
                    }
                    HStack {
                        Button("Tile windows in capture area…") { state.openTilePicker() }.disabled(!state.accessibilityAllowed || state.busy)
                        Spacer()
                        Button("Restore previous") { state.restorePrevious() }.disabled(!state.canUndo || state.busy)
                    }
                    Text("Saves open, visible windows on this desktop. Closed documents and other Spaces are not reopened.")
                        .font(.callout).foregroundStyle(.secondary)
                } header: { Text("Window layouts") } }

                if showPermissions { Section {
                    PermissionRow(name: "Accessibility", detail: "Save, tile and restore windows", allowed: state.accessibilityAllowed) { state.openPermission("Accessibility") }
                    PermissionRow(name: "Screen Recording", detail: "Capture the selected area", allowed: state.screenAllowed) { state.openPermission("ScreenCapture") }
                    Button("Refresh permissions") { state.refreshPermissions() }
                    Text("After enabling Screen Recording, quit and reopen Mischief Managed. Capture starts only when you choose Start preview.")
                        .font(.callout).foregroundStyle(.secondary)
                } header: { Text("macOS permissions") } }
                if let error = state.error {
                    Section {
                        Text(error).foregroundStyle(.primary).textSelection(.enabled)
                        Button("Dismiss message") { state.error = nil }
                    } header: { Label("Needs attention", systemImage: "exclamationmark.triangle") }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Image(systemName: state.capturing ? "record.circle" : "circle")
                Text(state.status).font(.callout).lineLimit(2).accessibilityAddTraits(.updatesFrequently)
                Spacer()
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 570, minHeight: 650)
        .sheet(isPresented: $state.showWindowPicker) { TilePicker().environmentObject(state) }
        .confirmationDialog("Delete “\(deletion?.name ?? "")”?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            Button("Delete saved layout", role: .destructive) { if let layout = deletion { state.deleteLayout(layout) }; deletion = nil }
        } message: { Text("This deletes only the saved arrangement. Your windows and documents stay open.") }
        .onChange(of: scenePhase) { _, phase in if phase == .active { state.refreshPermissions() } }
        .onAppear { snapshotIfRequested() }
    }
    private func snapshotIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "--integration-check"), args.indices.contains(flag+1) {
            let url = URL(fileURLWithPath: args[flag+1])
            Task { await IntegrationCheck.run(state: state, reportURL: url) }
            return
        }
        guard let flag = args.firstIndex(of: "--ui-snapshot"), args.indices.contains(flag+1) else { return }
        let path = args[flag+1]
        DispatchQueue.main.asyncAfter(deadline: .now()+1) {
            guard let window = NSApp.windows.first(where: { $0.title == "Mischief Managed" }), let view = window.contentView else { return }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }
}

struct GeometryEditor: View {
    @EnvironmentObject var state: AppState
    @ViewState private var x = "0"
    @ViewState private var y = "0"
    @ViewState private var width = "0"
    @ViewState private var height = "0"
    var body: some View {
        LabeledContent("Area in screen points") {
            HStack(spacing: 8) {
                field("X", text: $x); field("Y", text: $y)
                field("Width", text: $width); field("Height", text: $height)
                Button("Apply") { apply() }
            }
        }
        .onAppear { refresh() }
        .onChange(of: state.region) { _, _ in refresh() }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).labelsHidden().frame(minWidth: 42, maxWidth: 64)
                .accessibilityLabel("Capture area \(label), in screen points").onSubmit { apply() }
        }
    }
    private func refresh() {
        guard let display = state.display else { return }
        x = String(Int(state.region.minX-display.frame.minX)); y = String(Int(display.frame.maxY-state.region.maxY))
        width = String(Int(state.region.width)); height = String(Int(state.region.height))
    }
    private func apply() {
        guard let a = Double(x), let b = Double(y), let w = Double(width), let h = Double(height),
              [a,b,w,h].allSatisfy(\.isFinite), w > 0, h > 0, let display = state.display else {
            state.error = "Enter numbers for X and Y and positive numbers for width and height."; return
        }
        if state.capturing && !state.editing { state.capture.pauseForEditing() }
        state.setRegion(CGRect(x: display.frame.minX+a, y: display.frame.maxY-b-h, width: w, height: h))
    }
}

struct PermissionRow: View {
    let name: String
    let detail: String
    let allowed: Bool
    let action: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading) { Text(name); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if allowed { Label("Allowed", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            else { Button("Open settings…", action: action).accessibilityLabel("Open \(name) settings") }
        }
    }
}

struct TilePicker: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tile windows in capture area").font(.title2)
            Text("Choose the windows to arrange. Your current arrangement is kept for Restore previous.").foregroundStyle(.secondary)
            List(state.pickerWindows) { window in
                Toggle(window.label, isOn: Binding(get: { state.selectedWindows.contains(window.id) }, set: { value in
                    if value { state.selectedWindows.insert(window.id) } else { state.selectedWindows.remove(window.id) }
                }))
            }.frame(minHeight: 220)
            HStack {
                Button("Cancel") { state.showWindowPicker = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(state.selectedWindows.count) selected").foregroundStyle(.secondary)
                Button("Tile selected windows") { state.tileSelected() }.buttonStyle(.borderedProminent)
                    .disabled(state.selectedWindows.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 580, height: 390)
    }
}
