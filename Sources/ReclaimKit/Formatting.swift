import Foundation

/// Formats a byte count as a human-readable string (e.g. `"2.68 GB"`). Shared by the CLI and
/// by `Reclaimer`'s progress log so numbers read consistently everywhere.
public func formatBytes(_ bytes: Int64) -> String {
    let magnitude = abs(bytes)
    let units: [(threshold: Double, suffix: String)] = [
        (1024 * 1024 * 1024 * 1024, "TB"),
        (1024 * 1024 * 1024, "GB"),
        (1024 * 1024, "MB"),
        (1024, "KB")
    ]
    for unit in units where Double(magnitude) >= unit.threshold {
        let value = Double(bytes) / unit.threshold
        return String(format: "%.2f", value) + " " + unit.suffix
    }
    return "\(bytes) B"
}
