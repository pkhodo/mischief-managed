import SwiftUI

struct TaskAccessNotice: View {
    enum Feature {
        case arranging, sharing

        var pane: String { self == .arranging ? "Accessibility" : "ScreenCapture" }
        var permissionName: String { self == .arranging ? "Accessibility" : "Screen Recording" }
        var reason: String {
            self == .arranging ? "Allow window access to snap, save and restore windows."
                : "Allow screen access to start your preview."
        }
    }

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var manager: ActivityManager
    @ViewState private var requested = false
    let feature: Feature

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(feature.reason).foregroundStyle(.secondary)
            HStack {
                if requested {
                    Button("Open System Settings…") { state.openPermission(feature.pane) }
                    Button("Reopen app") { state.restartForPermissions(activityManager: manager) }
                        .disabled(state.busy || state.capturing || manager.busy || state.restarting)
                } else {
                    Button(feature == .arranging ? "Allow window access…" : "Allow screen access…") {
                        requested = true
                        state.requestPermission(feature.pane)
                    }.buttonStyle(.borderedProminent)
                }
            }
            if requested {
                Text("Enable Mischief Managed under \(feature.permissionName). If macOS asks you to reopen the app, use Reopen app.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
