import ArgumentParser
import Foundation
import ReclaimKit

/// `reclaim-cli caches` — lists dev-tool caches (Xcode DerivedData, npm, pnpm, Homebrew, ...,
/// and the per-app `~/Library/Caches` breakdown) and their sizes, and (as of M3a) can actually
/// delete a selection via `--run`.
///
/// Unlike `StatusCommand`/`CleanCommand` this does not call `detectBackendOrThrow()` — dev-tool
/// caches live on disk regardless of whether a Docker backend is running.
///
/// Without `--run` this is exactly the M1 read-only listing: nothing is scanned for deletion,
/// nothing is deleted. `--run` requires an explicit, non-empty selection (`--all-safe`,
/// `--only`, and/or positional `keys` are unioned together) — there is no "delete everything"
/// default.
struct CachesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "caches",
        abstract: "List dev-tool caches (Xcode DerivedData, npm, pnpm, Homebrew, per-app ~/Library/Caches, ...) and their sizes.",
        discussion: """
        Read-only by default: lists what Reclaim finds on disk and how much space each cache is
        using. Pass --run with a selection (--all-safe, --only <key>, and/or one or more
        positional keys) to actually delete the selected caches.
        """
    )

    /// How many of the largest per-app `~/Library/Caches` children to print before summarizing
    /// the rest — the full list can easily be 100+ entries.
    private static let maxAppCacheRowsShown = 10

    @Flag(name: .customLong("run"), help: "Actually delete the selected caches. Without this flag, caches only lists what's on disk.")
    var run: Bool = false

    @Option(name: .customLong("only"), help: "Select a cache by key/id (repeatable). Combine with --run to delete it.")
    var only: [String] = []

    @Argument(help: "Cache keys/ids to select — an alternative (or addition) to --only.")
    var keys: [String] = []

    @Flag(name: .customLong("all-safe"), help: "Select every regenerable single-directory cache (Xcode DerivedData, npm, pnpm, ... — not the per-app ~/Library/Caches children).")
    var allSafe: Bool = false

    @Flag(name: .customLong("notify"), help: "Post a macOS notification with the result (intended for scheduled runs).")
    var notify: Bool = false

    func run() async throws {
        if run {
            try await runSelectedClean()
        } else {
            printListing()
        }
    }

    private func printListing() {
        let catalog = CacheCatalog.default()
        let scanner = CacheScanner()
        let scanned = scanner.scan(catalog)

        let libraryCachesID = "library-caches"
        let topLevel = scanned
            .filter { $0.definitionID != libraryCachesID }
            .sorted { $0.sizeBytes > $1.sizeBytes }
        let appCaches = scanned.filter { $0.definitionID == libraryCachesID }

        print("Dev-tool caches — read-only listing (nothing is deleted):")
        print("")
        print(pad("  NAME", 34) + pad("SIZE", 12) + "KEY")

        for cache in topLevel {
            print(pad("  " + cache.displayName, 34) + pad(formatBytes(cache.sizeBytes), 12) + cache.id)
        }

        if !appCaches.isEmpty {
            let appCacheTotal = appCaches.reduce(Int64(0)) { $0 + $1.sizeBytes }
            print(pad("  App caches (~/Library/Caches)", 34) + pad(formatBytes(appCacheTotal), 12) + libraryCachesID)

            let topApps = appCaches.prefix(Self.maxAppCacheRowsShown)
            for app in topApps {
                print(pad("      " + app.displayName, 32) + pad(formatBytes(app.sizeBytes), 12) + app.id)
            }
            let remaining = appCaches.count - topApps.count
            if remaining > 0 {
                print("      ... and \(remaining) more app cache(s) not shown")
            }
        }

        let totalBytes = scanned.reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("")
        print("Total: \(formatBytes(totalBytes)) across \(scanned.count) cache location(s).")
        print("This is a listing only — nothing has been deleted. Pass --run with a selection (--all-safe / --only <key> / a key argument) to delete.")
    }

    /// Resolves the selection (`--all-safe` ∪ `--only` ∪ positional `keys`), then runs
    /// `CacheReclaimer.clean` with `dryRun: false` — `--run` always means "actually perform
    /// it" here, mirroring `CleanCommand`'s `--run` flag. There is no CLI-level dry-run preview
    /// of a selection in this milestone; the read-only listing above is the preview.
    private func runSelectedClean() async throws {
        let catalog = CacheCatalog.default()
        let scanner = CacheScanner()
        let scanned = scanner.scan(catalog)
        let scannedIDs = Set(scanned.map(\.id))

        var selection: Set<String> = []
        if allSafe {
            // Every regenerable SINGLE-directory cache's own id — never the per-app
            // `library-caches` children, whose definitionID ("library-caches") never matches a
            // scanned id here (that definition is `.perAppChildren`, so its own scanned ids are
            // "library-caches/<app>", not "library-caches").
            let safeDefinitionIDs = Set(
                catalog
                    .filter { $0.expansion == .singleDirectory && $0.regenerates }
                    .map(\.id)
            )
            selection.formUnion(scannedIDs.filter { safeDefinitionIDs.contains($0) })
        }
        selection.formUnion(only)
        selection.formUnion(keys)

        guard !selection.isEmpty else {
            throw CLIError(message: """
            No caches selected. Pass --all-safe, --only <key>, and/or one or more cache keys, e.g.:
              reclaim-cli caches --run --all-safe
              reclaim-cli caches --run --only npm --only pnpm
              reclaim-cli caches --run library-caches/com.apple.Safari
            """)
        }

        let options = CleanOptions(dryRun: !run)

        print("Dev-tool caches — deleting \(selection.count) selected cache(s):")
        if options.dryRun {
            print("DRY RUN — no files will be removed.\n")
        } else {
            print("")
        }

        let reclaimer = CacheReclaimer()
        let report = try await reclaimer.clean(selection: selection, options: options, catalog: catalog) { event in
            switch event {
            case .step(let text):
                print("==> \(text)")
            case .log(let text):
                print("    \(text)")
            case .done:
                break
            }
        }

        print("")
        if report.dryRun {
            let estimatedTotal = report.steps.reduce(Int64(0)) { $0 + $1.dockerReportedBytes }
            print("Would free roughly \(formatBytes(estimatedTotal)) (pass --run to actually delete).")
        } else {
            print("Freed \(formatBytes(report.hostDelta)) on macOS (host free: \(formatBytes(report.hostFreeBefore)) \u{2192} \(formatBytes(report.hostFreeAfter)))")

            let entry = HistoryEntry(
                date: Date(),
                backend: nil,
                imagesReclaimed: 0,
                buildCacheReclaimed: 0,
                containersReclaimed: 0,
                trimmedBytes: 0,
                hostDelta: report.hostDelta,
                source: .caches,
                cachesReclaimed: report.hostDelta
            )
            do {
                try HistoryStore().append(entry)
            } catch {
                FileHandle.standardError.write(Data("warning: failed to record history: \(error)\n".utf8))
            }

            if notify {
                notifyUser(message: "Freed \(formatBytes(report.hostDelta)) from dev-tool caches")
            }
        }
    }
}
