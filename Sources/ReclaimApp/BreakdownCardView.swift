import SwiftUI
import ReclaimKit

/// One breakdown row (Build Cache / Images / Containers / Volumes), rendered as a stock
/// `GroupBox` — no custom glass/vibrancy chrome, per the locked UI-style decision in
/// docs/IMPLEMENTATION.md.
struct BreakdownCardView: View {
    let title: String
    let systemImage: String
    let total: Int64
    let reclaimable: Int64
    var subtitle: String?
    var isProtected: Bool = false

    var body: some View {
        GroupBox {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatBytes(total))
                        .font(.subheadline.monospacedDigit())
                    if isProtected {
                        Text(subtitle ?? "never touched")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(formatBytes(reclaimable)) reclaimable")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
