import SwiftUI

/// Free-space color state for the menu bar icon.
///
/// Thresholds per docs/IMPLEMENTATION.md ("App (M1-M4)"): green at >=15% of volume capacity
/// free, amber at 8-15%, red below 8%. A menu bar status item label frequently can't render
/// a custom tint reliably (macOS often forces template/monochrome rendering there), so for
/// the red state we additionally swap the SF Symbol itself to a warning triangle rather than
/// depending on color alone — the same fallback IMPLEMENTATION.md calls for.
enum DiskLevel: Equatable {
    case green
    case amber
    case red

    init(freeBytes: Int64, totalBytes: Int64) {
        guard totalBytes > 0 else {
            self = .green
            return
        }
        let percentFree = Double(freeBytes) / Double(totalBytes) * 100
        if percentFree < 8 {
            self = .red
        } else if percentFree < 15 {
            self = .amber
        } else {
            self = .green
        }
    }

    var color: Color {
        switch self {
        case .green: return .green
        case .amber: return .orange
        case .red: return .red
        }
    }

    /// `internaldrive` for green/amber; `exclamationmark.triangle` for red so the state still
    /// reads correctly even if the status bar strips the tint color.
    var symbolName: String {
        switch self {
        case .green, .amber: return "internaldrive"
        case .red: return "exclamationmark.triangle"
        }
    }
}
