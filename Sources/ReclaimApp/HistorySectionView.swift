import SwiftUI
import ReclaimKit

/// A one-line "Last cleanup" summary plus the full run history, tucked behind a
/// `DisclosureGroup` (docs/design/panel.html: "Last cleanup: 3 days ago · 12.4 GB returned"
/// above the collapsible full list). Backed by `HistoryStore` (docs/IMPLEMENTATION.md, App
/// M1-M4).
struct HistorySectionView: View {
    @EnvironmentObject var appState: AppState
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let last = appState.history.first {
                HStack {
                    Text("Last cleanup: \(relativeDateText(last.date))")
                        .font(.caption)
                    Spacer()
                    Text("\(appFormatBytes(last.hostDelta)) returned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
                                Text(entry.backend?.displayName ?? "Dev caches")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(appFormatBytes(entry.hostDelta))
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func relativeDateText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
