import SwiftUI
import ServiceManagement

/// The M4 "Clean weekly" toggle, backed by `SMAppService.agent`. Off by default — flipping
/// this is the *only* thing that registers the LaunchAgent (docs/IMPLEMENTATION.md, App M4).
struct SchedulingSectionView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "Clean weekly (Sunday, 10:00 AM)",
                isOn: Binding(
                    get: { appState.schedulingStatus == .enabled },
                    set: { appState.setSchedulingEnabled($0) }
                )
            )

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = appState.schedulingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { appState.refreshSchedulingStatus() }
    }

    private var statusText: String {
        switch appState.schedulingStatus {
        case .enabled:
            return "On — runs reclaim-cli clean --run --notify every Sunday at 10:00 AM. macOS may ask you to approve this under System Settings > General > Login Items."
        case .requiresApproval:
            return "Needs approval — open System Settings > General > Login Items to allow it."
        case .notFound:
            return "Scheduling helper not found in this build."
        case .notRegistered:
            return "Off."
        @unknown default:
            return "Unknown status."
        }
    }
}
