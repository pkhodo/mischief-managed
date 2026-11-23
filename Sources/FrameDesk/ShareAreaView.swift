import SwiftUI
import FrameDeskCore

struct ShareAreaView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Share part of your screen").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Done") {
                    if state.editing { state.toggleEditing() }
                    dismiss()
                }.disabled(state.editing && state.busy).keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    areaControls
                    Divider()
                    previewControls
                    if let error = state.error {
                        Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                        Button("Dismiss message") { state.error = nil }
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(state.restarting)
        .onAppear { state.refreshPermissions() }
        .onChange(of: phase) { _, value in if value == .active { state.refreshPermissions() } }
    }

    private var areaControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose what to share").font(.headline)
            if let display = state.display {
                areaDiagram(display)
                Text(state.editing ? "Drag the orange outline or its handles, then choose Done adjusting." : "The orange rectangle is the area your preview will show.")
                    .font(.callout).foregroundStyle(.secondary)
                Button(state.editing ? "Done adjusting" : "Move or resize area") { state.toggleEditing() }
                    .disabled(state.busy)
                DisclosureGroup("Display, presets and exact size") {
                    VStack(alignment: .leading, spacing: 10) {
                        if state.displays.count > 1 {
                            Picker("Display", selection: Binding(get: { state.displayID }, set: { state.chooseDisplay($0) })) {
                                ForEach(state.displays) { Text($0.name).tag($0.id) }
                            }
                        }
                        HStack {
                            Text("Place in a corner")
                            ForEach(Array(["Top left", "Top right", "Bottom left", "Bottom right"].enumerated()), id: \.offset) { index, title in
                                Button(title) { state.resetArea(corner: index) }
                            }
                        }
                        GeometryEditor()
                    }.padding(.top, 8).disabled(state.busy)
                }
            } else {
                Text("Connect a display to choose an area.").foregroundStyle(.secondary)
            }
        }
    }

    private var previewControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Share the preview in your call").font(.headline)
            if state.screenAllowed || state.capturing {
                HStack {
                    Button(state.capturing ? "Stop preview" : "Start preview") {
                        if state.capturing { state.stopCapture() } else { state.startCapture() }
                    }.buttonStyle(.borderedProminent).disabled(state.busy || state.display == nil)
                    if state.busy { ProgressView().controlSize(.small).accessibilityLabel("Updating preview") }
                    if state.capturing {
                        Button("Show preview window") { state.capture.showPreview(region: state.region) }
                    }
                }
                if state.capturing {
                    Text(state.editing ? "Preview paused while you adjust the area." : "In your call, choose Window, then select “Mischief Managed — Share this window”.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Start the preview, then pick its window in your meeting’s share menu.")
                        .foregroundStyle(.secondary)
                }
            } else {
                TaskAccessNotice(feature: .sharing)
            }
        }
    }

    private func areaDiagram(_ display: Display) -> some View {
        let area = Geometry.normalized(state.region, in: display.frame).rect
        return GeometryReader { view in
            let areaWidth = area.width * view.size.width
            let areaHeight = area.height * view.size.height
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topLeading) {
                    Rectangle().fill(.orange.opacity(0.15))
                        .overlay(Rectangle().strokeBorder(.orange, lineWidth: 2))
                        .frame(width: areaWidth, height: areaHeight)
                        .offset(x: area.minX * view.size.width, y: (1 - area.maxY) * view.size.height)
                }
        }
        .aspectRatio(display.frame.width / max(1, display.frame.height), contentMode: .fit)
        .frame(maxWidth: 320, maxHeight: 160)
        .accessibilityLabel("Selected sharing area on \(display.name)")
    }
}
