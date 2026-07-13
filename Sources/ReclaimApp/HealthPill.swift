import SwiftUI
import ReclaimKit

/// Top-right capsule in the header (matches `.pill` in panel.html) — a 6pt colored dot plus an
/// 11pt semibold label, on a ~16-20%-alpha tinted background. Driven by the same `DiskLevel`
/// thresholds as the menu bar icon (green >=15% free, amber 8-15%, red <8%; see
/// `DiskLevel.swift`) — this is the one health signal, shown twice in two different shapes.
struct HealthPill: View {
    let level: DiskLevel

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dotColor).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(dotColor.opacity(0.18)))
    }

    private var label: String {
        switch level {
        case .green: return "Healthy"
        case .amber: return "Low"
        case .red: return "Critical"
        }
    }

    private var dotColor: Color {
        switch level {
        case .green: return Palette.healthGreenDot
        case .amber: return Color(nsColor: .systemOrange)
        case .red: return Color(nsColor: .systemRed)
        }
    }

    private var foregroundColor: Color {
        switch level {
        case .green: return Palette.healthGreenFG
        case .amber: return Color(nsColor: .systemOrange)
        case .red: return Color(nsColor: .systemRed)
        }
    }
}
