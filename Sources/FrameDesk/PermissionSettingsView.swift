import SwiftUI
import AppKit

struct PermissionSettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var manager: ActivityManager
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DisplayScenesView(embedded: true).environmentObject(state.tiling)
                Divider()
                Text("Permissions").font(.title2).fontWeight(.semibold)
                permission("Accessibility", allowed: state.accessibilityAllowed,
                           detail: "Snap, save and restore window positions.", pane: "Accessibility")
                permission("Screen Recording", allowed: state.screenAllowed,
                           detail: "Preview and share a screen area.", pane: "ScreenCapture")
                DisclosureGroup("Website automation") {
                    HStack(alignment: .top) {
                        Text("macOS asks for Edge access when you first open a website activity.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 16)
                        Button("Open Automation…") { state.openPermission("Automation") }
                    }.padding(.top, 6)
                }
                if !state.accessibilityAllowed || !state.screenAllowed {
                    DisclosureGroup("Permission help") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("If you just granted access, restart the app. If access is still unavailable, check that this copy is enabled in System Settings.")
                            Text(Bundle.main.bundleURL.path).textSelection(.enabled)
                            Button("Restart app") { state.restartForPermissions(activityManager: manager) }
                                .disabled(state.busy || state.capturing || manager.busy || state.restarting)
                        }.font(.callout).padding(.top, 6)
                    }
                }
                if let error = state.error { Text(error).font(.callout).textSelection(.enabled) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 640, height: 690)
        .disabled(state.restarting)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { state.refreshPermissions() }
        .onChange(of: phase) { _, value in if value == .active { state.refreshPermissions() } }
    }

    private func permission(_ title: String, allowed: Bool, detail: String, pane: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                Label(allowed ? "Enabled" : "Not available to this app", systemImage: allowed ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.callout)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 8) {
                if !allowed {
                    Button("Request access…") { state.requestPermission(pane) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Request \(pane == "ScreenCapture" ? "Screen Recording" : pane) access")
                }
                Button("Open \(pane == "ScreenCapture" ? "Screen Recording" : pane)…") { state.openPermission(pane) }
            }
        }
    }
}
