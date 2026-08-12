import Foundation

/// Read-only probe for whether the process has Full Disk Access: attempts to list the contents
/// of each TCC-gated location under `home` that macOS silently blocks (or restricts to an empty
/// listing) without it. `LargeItemScanner` needs Full Disk Access to see inside these
/// locations, so this probe lets a caller find out up front rather than discovering silent gaps
/// only via `LargeScanResult.skippedAreas` after a full scan.
///
/// Deliberately read-only and framework-minimal: no AppKit, no `NSWorkspace`. Turning
/// `needsFullDiskAccess` into a "grant Full Disk Access" banner and a
/// `x-apple.systempreferences:...Privacy_AllFiles` deep-link button lives in the app layer.
public struct FullDiskAccessProbe {
    /// Locations, relative to `home`, that macOS gates behind Full Disk Access / TCC.
    private static let tccGatedRelativePaths = [
        "Desktop",
        "Documents",
        "Downloads",
        "Movies",
        "Music",
        "Pictures",
        "Library/Mobile Documents",
        "Library/CloudStorage"
    ]

    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public struct Result: Equatable {
        public let readableAreas: [String]
        public let unreadableAreas: [String]

        public init(readableAreas: [String], unreadableAreas: [String]) {
            self.readableAreas = readableAreas
            self.unreadableAreas = unreadableAreas
        }

        public var needsFullDiskAccess: Bool { !unreadableAreas.isEmpty }
    }

    /// Attempts a read-only directory listing of each TCC-gated area that exists on disk. An
    /// area that doesn't exist on disk (e.g. no iCloud Drive configured) is skipped entirely —
    /// its absence isn't a permissions problem, so it is reported in neither list. A throw from
    /// `contentsOfDirectory` means the area is (most likely) blocked by TCC; success means it is
    /// readable.
    public func probe() -> Result {
        var readableAreas: [String] = []
        var unreadableAreas: [String] = []

        let homeURL = URL(fileURLWithPath: home)
        for relativePath in Self.tccGatedRelativePaths {
            let url = homeURL.appendingPathComponent(relativePath, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            do {
                _ = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [],
                    options: []
                )
                readableAreas.append(relativePath)
            } catch {
                unreadableAreas.append(relativePath)
            }
        }

        return Result(readableAreas: readableAreas, unreadableAreas: unreadableAreas)
    }
}
