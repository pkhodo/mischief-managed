import SwiftUI
import AppKit

struct PermissionSettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var manager: ActivityManager
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DisplayScenesView(embedded: true).environmentObject(state.tiling)
                if !state.accessibilityAllowed || !state.screenAllowed {
                    Divider()
                    Text("Access needed").font(.title2).fontWeight(.semibold)
                    if !state.accessibilityAllowed { TaskAccessNotice(feature: .arranging) }
                    if !state.screenAllowed { TaskAccessNotice(feature: .sharing) }
                }
                Divider()
                DisclosureGroup("Troubleshooting") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("Accessibility…") { state.openPermission("Accessibility") }
                            Button("Screen Recording…") { state.openPermission("ScreenCapture") }
                            Button("Edge Automation…") { state.openPermission("Automation") }
                        }
                        Text("If access is still unavailable, check that this copy is enabled in System Settings.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(Bundle.main.bundleURL.path).font(.callout).textSelection(.enabled)
                        Button("Reopen app") { state.restartForPermissions(activityManager: manager) }
                            .disabled(state.busy || state.capturing || manager.busy || state.restarting)
                    }.padding(.top, 8)
                }
                if let error = state.error { Text(error).font(.callout).textSelection(.enabled) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 640, height: 570)
        .disabled(state.restarting)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { state.refreshPermissions() }
        .onChange(of: phase) { _, value in if value == .active { state.refreshPermissions() } }
    }
}
