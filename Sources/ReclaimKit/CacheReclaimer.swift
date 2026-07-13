import Foundation

/// Orchestrates a dev-tool cache cleanup end to end: probe host free space, delete every
/// selected `ScannedCache` (or, in a dry run, size-and-validate-but-not-delete it), probe
/// again, and report the real `statfs` delta. Reuses `CleanOptions`/`CleanEvent`/`CleanReport`
/// from `Reclaimer` so the CLI (and, later, the menu bar UI) can stream and print both engines
/// through the same code (docs/plan: "additive, not a protocol retrofit").
///
/// `CacheReclaimer` never removes a file itself — every real deletion is delegated to
/// `CacheDeleter`, the sole audited deletion chokepoint in `Sources/` (enforced by
/// `CacheDeleterIsolationTests` and a matching CI grep gate — see `.github/workflows/ci.yml`'s
/// `safety-regression` job). This mirrors how `Reclaimer` never touches the Docker socket
/// directly, always routing through `DockerClient.send`.
public struct CacheReclaimer {
    private let home: String
    private let diskProbePath: String

    public init(home: String = NSHomeDirectory(), diskProbePath: String = "/") {
        self.home = home
        self.diskProbePath = diskProbePath
    }

    /// Cleans every `ScannedCache` whose `id` is in `selection`.
    ///
    /// `selection` holds `ScannedCache.id`s: for a `.singleDirectory` catalog entry that's just
    /// the definition id (e.g. `"npm"`); for the `.perAppChildren` `library-caches` entry these
    /// are the per-app child ids produced by `CacheScanner` (e.g.
    /// `"library-caches/com.apple.Safari"`). There is no id that ever resolves to the whole
    /// `~/Library/Caches` root — `CacheScanner` never produces a `ScannedCache` for that root,
    /// only for its children — so this can never hand the `Library/Caches` directory itself to
    /// `CacheDeleter`.
    ///
    /// If a selected id isn't present in the current scan (it may have vanished from disk since
    /// the caller last listed caches), it is skipped with a `.log` rather than treated as an
    /// error — the rest of the selection still runs.
    public func clean(
        selection: Set<String>,
        options: CleanOptions = CleanOptions(),
        catalog: [CacheDefinition] = CacheCatalog.default(),
        progress: @escaping (CleanEvent) -> Void = { _ in }
    ) async throws -> CleanReport {
        progress(.step("Checking free space"))
        let before = try DiskProbe.stat(path: diskProbePath)

        let scanner = CacheScanner(home: home)
        let scanned = scanner.scan(catalog)
        let scannedByID = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })

        let allowedRoots = CacheDeleter.allowedRoots(for: catalog, home: home)
        let deleter = CacheDeleter(home: home)

        var steps: [CleanStepResult] = []
        for id in selection.sorted() {
            guard let cache = scannedByID[id] else {
                progress(.log("Skipping \(id) — not found in the current scan (it may have vanished since listing)"))
                continue
            }

            progress(.step("Clearing \(cache.displayName)"))
            let result = try deleter.delete(cache, allowedRoots: allowedRoots, dryRun: options.dryRun)
            let verb = options.dryRun ? "would be freed" : "freed"
            progress(.log("\(cache.displayName): \(formatBytes(result.bytesBefore)) \(verb)"))
            steps.append(CleanStepResult(name: cache.displayName, dockerReportedBytes: result.bytesBefore))
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
