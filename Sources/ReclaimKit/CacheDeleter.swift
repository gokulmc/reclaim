import Foundation

/// The outcome of deleting (or dry-running the deletion of) one `ScannedCache`.
public struct CacheDeleteResult: Equatable {
    public let definitionID: String
    /// The paths that were removed — or, in a `dryRun`, the paths that WOULD have been
    /// removed. Every path here already passed `CacheSafetyGuard.validate`.
    public let removedPaths: [String]
    /// Total bytes measured (via `DirectorySizer`) across `removedPaths` before any removal.
    public let bytesBefore: Int64

    public init(definitionID: String, removedPaths: [String], bytesBefore: Int64) {
        self.definitionID = definitionID
        self.removedPaths = removedPaths
        self.bytesBefore = bytesBefore
    }
}

/// The single, audited chokepoint for real on-disk cache deletion — the **only**
/// `FileManager.removeItem` call site anywhere in `Sources/` (enforced by
/// `CacheDeleterIsolationTests` and a CI grep gate; see `.github/workflows/ci.yml`'s
/// `safety-regression` job). Every candidate path is validated by `CacheSafetyGuard`
/// immediately before it is removed — nothing is ever deleted without passing that gate
/// first, mirroring how `DockerClient.send` routes every request through `SafetyGuard`.
public struct CacheDeleter {
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    /// Derives the set of allowed catalog roots (as absolute URLs joined to `home`) from a
    /// cache catalog, so callers never hand-roll the `allowedRoots` list passed to
    /// `CacheSafetyGuard.validate` themselves.
    public static func allowedRoots(for catalog: [CacheDefinition], home: String) -> [URL] {
        catalog.flatMap { definition in
            definition.relativePaths.map { relativePath in
                URL(fileURLWithPath: home).appendingPathComponent(relativePath, isDirectory: true)
            }
        }
    }

    /// Deletes every existing path in `scanned`, validating each one against
    /// `CacheSafetyGuard.validate` immediately before removing it. If validation fails for any
    /// path, this throws immediately: paths already removed earlier in the loop (if any) stay
    /// removed, but the failing path and everything after it are left untouched.
    ///
    /// In `dryRun`, every path is still validated and sized, but `FileManager.removeItem` is
    /// never called — `removedPaths` reports what WOULD be removed, and `bytesBefore` is the
    /// real measured size, even though nothing was actually deleted.
    public func delete(_ scanned: ScannedCache, allowedRoots: [URL], dryRun: Bool) throws -> CacheDeleteResult {
        var removedPaths: [String] = []
        var bytesBefore: Int64 = 0

        for url in scanned.existingPaths {
            try CacheSafetyGuard.validate(target: url, home: home, allowedRoots: allowedRoots)

            bytesBefore += DirectorySizer.size(of: url)

            if !dryRun {
                try FileManager.default.removeItem(at: url)
            }

            removedPaths.append(url.path)
        }

        return CacheDeleteResult(
            definitionID: scanned.definitionID,
            removedPaths: removedPaths,
            bytesBefore: bytesBefore
        )
    }
}
