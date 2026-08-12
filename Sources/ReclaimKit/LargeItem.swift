import Foundation

/// One item surfaced by `LargeItemScanner` — either a large file or a large folder (an "opaque
/// bundle" like a `.app` counts as one folder item; an ordinary folder is only offered when its
/// subtree total clears `folderThresholdBytes` within `folderRankMaxDepth`). Purely a read-only
/// view-model value: producing one only measures the filesystem, never touches it, and nothing
/// here can delete anything.
public struct LargeItem: Identifiable, Equatable {
    /// The canonical (symlink-resolved, standardized) path — a stable identity even if the same
    /// physical location happens to be reachable through more than one route.
    public let id: String
    public let url: URL
    public let path: String
    public let sizeBytes: Int64
    public let isDirectory: Bool
    /// `true` when `FileTrashGuard.validate` rejects this item — surfaced 🔒 and non-selectable
    /// in the UI, never eligible for the (later-milestone) real move-to-Trash.
    public let isProtected: Bool

    public init(
        id: String,
        url: URL,
        path: String,
        sizeBytes: Int64,
        isDirectory: Bool,
        isProtected: Bool
    ) {
        self.id = id
        self.url = url
        self.path = path
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.isProtected = isProtected
    }

    public var isSelectable: Bool { !isProtected }
}

/// Live progress emitted while `LargeItemScanner.scan` walks the home directory.
public struct LargeScanProgress: Equatable {
    public let filesScanned: Int
    public let currentArea: String

    public init(filesScanned: Int, currentArea: String) {
        self.filesScanned = filesScanned
        self.currentArea = currentArea
    }
}

/// The final, immutable result of one `LargeItemScanner.scan` call.
public struct LargeScanResult: Equatable {
    public let items: [LargeItem]
    /// Directories the scan could not read (Full Disk Access / TCC gaps) — recorded rather than
    /// silently swallowed, so callers can surface an honest "some areas were skipped" notice
    /// instead of presenting a partial scan as exhaustive.
    public let skippedAreas: [String]
    public let filesScanned: Int
    public let wasCancelled: Bool

    public init(
        items: [LargeItem],
        skippedAreas: [String],
        filesScanned: Int,
        wasCancelled: Bool
    ) {
        self.items = items
        self.skippedAreas = skippedAreas
        self.filesScanned = filesScanned
        self.wasCancelled = wasCancelled
    }
}
