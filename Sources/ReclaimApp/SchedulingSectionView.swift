import SwiftUI
import ServiceManagement

/// The M4 "Clean up automatically every week" toggle, backed by `SMAppService.agent`. Off by
/// default — flipping this is the *only* thing that registers the LaunchAgent
/// (docs/IMPLEMENTATION.md, App M4).
struct SchedulingSectionView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                isOn: Binding(
                    get: { appState.schedulingStatus == .enabled },
                    set: { appState.setSchedulingEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Clean up automatically every week")
                    Text("Sundays at 10:00 — you’ll get a notification with the result.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let statusNote {
                Text(statusNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = appState.schedulingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { appState.refreshSchedulingStatus() }
    }

    /// Operationally important detail that stays even after the redesign's plain-language
    /// pass — a layman still needs to know when macOS is asking them to approve a login item.
    /// The routine "off"/"on, runs reclaim-cli clean --run --notify..." status text is dropped
    /// since the toggle's own caption above now says exactly that in plain language.
    private var statusNote: String? {
        switch appState.schedulingStatus {
        case .enabled:
            return "macOS may ask you to approve this under System Settings > General > Login Items."
        case .requiresApproval:
            return "Needs approval — open System Settings > General > Login Items to allow it."
        case .notFound:
            return "Scheduling helper not found in this build."
        case .notRegistered:
            return nil
        @unknown default:
            return nil
        }
    }
}
