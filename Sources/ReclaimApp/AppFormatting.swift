import Foundation

/// App-local byte formatter — same units/thresholds as `ReclaimKit.formatBytes`, but capped at
/// **one decimal place**, everywhere (docs/design/copy.html: "53.70 GB free of 460.43 GB" →
/// "53.7 GB free on your Mac" — "one decimal max, everywhere. '460.43' precision reads as
/// engineering output.").
///
/// `ReclaimKit.formatBytes` (two-decimal) stays exactly as-is: the CLI and `Reclaimer`'s own
/// progress log both depend on it, and this redesign explicitly does not touch ReclaimKit or
/// CLI technical output. This formatter is UI-only, lives in the app target, and is used for
/// every byte value the panel and menu bar label show.
func appFormatBytes(_ bytes: Int64) -> String {
    format(bytes, maxDecimals: 1)
}

/// Whole-number variant for the menu bar label, where the design shows "54 GB", not
/// "53.7 GB" (docs/design/menubar-icon.html, "At real size, in the menu bar") — every point
/// of status-bar width counts.
func appFormatBytesWhole(_ bytes: Int64) -> String {
    format(bytes, maxDecimals: 0)
}

private func format(_ bytes: Int64, maxDecimals: Int) -> String {
    let magnitude = abs(bytes)
    let units: [(threshold: Double, suffix: String)] = [
        (1024 * 1024 * 1024 * 1024, "TB"),
        (1024 * 1024 * 1024, "GB"),
        (1024 * 1024, "MB"),
        (1024, "KB")
    ]
    for unit in units where Double(magnitude) >= unit.threshold {
        let value = Double(bytes) / unit.threshold
        var text = String(format: "%.\(maxDecimals)f", value)
        // "One decimal max" — never a forced ".0" ("54 GB", not "54.0 GB").
        if text.hasSuffix(".0") {
            text.removeLast(2)
        }
        return text + " " + unit.suffix
    }
    return "\(bytes) B"
}
