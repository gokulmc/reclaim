import AppKit

/// Free-space color state for the menu bar icon.
///
/// Thresholds per docs/IMPLEMENTATION.md ("App (M1-M4)"): green at >=15% of volume capacity
/// free, amber at 8-15%, red below 8%. The menu bar glyph (`MenuBarIcon`) keeps the same
/// Concept-A shape at every severity — only its color changes, via `nsColor` below, which
/// drives whether the rendered `NSImage` is a template (monochrome, adapts to the menu bar)
/// or a non-template image baked with an explicit warning color.
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

    /// `nil` for the green (plenty of space) state — renders `MenuBarIcon` as a template
    /// image so AppKit recolors it to match the light/dark menu bar automatically. Amber/red
    /// return an explicit `NSColor`, which `MenuBarIcon.image(tint:)` bakes into the image as
    /// a non-template render so the warning color actually shows in the status bar.
    var nsColor: NSColor? {
        switch self {
        case .green: return nil
        case .amber: return .systemOrange
        case .red: return .systemRed
        }
    }
}
