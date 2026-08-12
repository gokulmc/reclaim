import Foundation

/// Orchestrates a large-files-to-Trash run end to end: probe host free space, move every
/// selected `LargeItem` to the Trash (or, in a dry run, size-and-validate-but-not-move it),
/// probe again, and report the real `statfs` delta. Reuses `CleanOptions`/`CleanEvent`/
/// `CleanReport` from `Reclaimer` so the CLI (and the menu bar UI) can stream and print this
/// engine through the same code, exactly as `CacheReclaimer` does.
///
/// `LargeFilesReclaimer` never moves a file itself — every real move-to-Trash is delegated to
/// `FileTrasher`, the sole audited move-to-Trash chokepoint in `Sources/` (enforced by
/// `FileTrasherIsolationTests` and a matching CI grep gate — see `.github/workflows/ci.yml`'s
/// `safety-regression` job).
public struct LargeFilesReclaimer {
    private let home: String
    private let diskProbePath: String

    public init(home: String = NSHomeDirectory(), diskProbePath: String = "/") {
        self.home = home
        self.diskProbePath = diskProbePath
    }

    /// Moves every item in `selection` to the Trash.
    ///
    /// `selection` is sorted by `url.path.count` ascending before processing — a shorter path
    /// is never nested inside a longer one selected alongside it, so this guarantees a parent
    /// folder is always moved before any of its selected descendants. A descendant that no
    /// longer exists once its parent has already been moved (it went to the Trash along with
    /// it) is skipped with a `.log` rather than treated as an error — the rest of the selection
    /// still runs.
    ///
    /// A `FileTrashGuard` violation on any remaining item is NOT caught here: it propagates and
    /// aborts the whole run, mirroring `CacheReclaimer.clean`, which never catches
    /// `CacheDeleter.delete`'s `CacheSafetyGuard.Violation` either.
    public func trash(
        selection: [LargeItem],
        options: CleanOptions = CleanOptions(),
        progress: @escaping (CleanEvent) -> Void = { _ in }
    ) async throws -> CleanReport {
        progress(.step("Checking free space"))
        let before = try DiskProbe.stat(path: diskProbePath)

        let sorted = selection.sorted { $0.url.path.count < $1.url.path.count }
        let trasher = FileTrasher(home: home)

        var steps: [CleanStepResult] = []
        for item in sorted {
            let name = item.url.lastPathComponent

            guard FileManager.default.fileExists(atPath: item.url.path) else {
                progress(.log("\(name): already trashed with its parent — skipping"))
                continue
            }

            let result = try trasher.trash(item, dryRun: options.dryRun)
            progress(.step("Moving \(name) to Trash"))
            let verb = options.dryRun ? "would be moved" : "moved to Trash"
            progress(.log("\(name): \(formatBytes(result.bytesBefore)) \(verb)"))
            steps.append(CleanStepResult(name: name, dockerReportedBytes: result.bytesBefore))
        }

        progress(.step("Re-checking free space"))
        let after = try DiskProbe.stat(path: diskProbePath)

        let report = CleanReport(
            dryRun: options.dryRun,
            backend: nil,
            hostFreeBefore: before.freeBytes,
            hostFreeAfter: after.freeBytes,
            steps: steps,
            trimmedBytes: 0,
            trimNote: nil
        )
        progress(.done(report))
        return report
    }
}
