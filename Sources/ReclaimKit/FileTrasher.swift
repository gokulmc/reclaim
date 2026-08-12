import Foundation

/// The outcome of trashing (or dry-running the trash of) one `LargeItem`.
public struct FileTrashResult: Equatable {
    public let path: String
    /// Where the item landed after being moved to the Trash (`FileManager`'s
    /// `resultingItemURL`), `nil` in a `dryRun` since nothing was actually moved.
    public let trashedPath: String?
    /// Bytes measured (via `DirectorySizer.allocatedSize`) for `path` before any move.
    public let bytesBefore: Int64

    public init(path: String, trashedPath: String?, bytesBefore: Int64) {
        self.path = path
        self.trashedPath = trashedPath
        self.bytesBefore = bytesBefore
    }
}

/// The single, audited chokepoint for real on-disk move-to-Trash — the **only** move-to-Trash
/// call site anywhere in `Sources/` (enforced by `FileTrasherIsolationTests` and a CI grep
/// gate; see `.github/workflows/ci.yml`'s `safety-regression` job). Every candidate is
/// validated by `FileTrashGuard` immediately before it is moved — nothing is ever trashed
/// without passing that gate first — mirroring how `CacheDeleter` is the sole audited
/// real-deletion call site for dev-tool caches.
///
/// This type never permanently deletes anything: the underlying `FileManager` API moves the
/// target to `~/.Trash` (recoverable), not off disk. That recoverability is the primary safety
/// net for the whole large-files feature (see `FileTrashGuard`'s doc comment).
public struct FileTrasher {
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    /// Moves `item` to the Trash, validating it against `FileTrashGuard.validate` immediately
    /// beforehand. In `dryRun`, `item` is still validated and sized, but the real move-to-Trash
    /// call is never made — `trashedPath` is `nil` and `bytesBefore` is the real measured size,
    /// even though nothing was actually moved.
    public func trash(_ item: LargeItem, dryRun: Bool) throws -> FileTrashResult {
        try FileTrashGuard.validate(target: item.url, home: home)

        let bytes = DirectorySizer.allocatedSize(of: item.url)

        if !dryRun {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
            return FileTrashResult(path: item.url.path, trashedPath: (resulting as URL?)?.path, bytesBefore: bytes)
        }

        return FileTrashResult(path: item.url.path, trashedPath: nil, bytesBefore: bytes)
    }
}
