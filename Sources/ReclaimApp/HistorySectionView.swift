import SwiftUI
import ReclaimKit

/// Collapsible list of past runs, backed by `HistoryStore` (docs/IMPLEMENTATION.md, App
/// M1-M4).
struct HistorySectionView: View {
    @EnvironmentObject var appState: AppState
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("History (\(appState.history.count))", isExpanded: $isExpanded) {
            if appState.history.isEmpty {
                Text("No runs yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(appState.history.prefix(20).enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Text(entry.date, style: .date)
                                .font(.caption)
                            Spacer()
                            Text(entry.backend.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(formatBytes(entry.hostDelta))
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}
