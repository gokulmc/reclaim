import ArgumentParser
import Foundation
import ReclaimKit

/// `reclaim-cli caches` — read-only listing of dev-tool caches (Xcode DerivedData, npm,
/// pnpm, Homebrew, ..., and the per-app `~/Library/Caches` breakdown) and their sizes.
///
/// This milestone is list-only: no `--run`, no selection, no deletion. Unlike `StatusCommand`
/// this does not call `detectBackendOrThrow()` — dev-tool caches live on disk regardless of
/// whether a Docker backend is running.
struct CachesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "caches",
        abstract: "List dev-tool caches (Xcode DerivedData, npm, pnpm, Homebrew, per-app ~/Library/Caches, ...) and their sizes.",
        discussion: """
        Read-only: lists what Reclaim finds on disk and how much space each cache is using.
        Nothing is deleted by this command.
        """
    )

    /// How many of the largest per-app `~/Library/Caches` children to print before summarizing
    /// the rest — the full list can easily be 100+ entries.
    private static let maxAppCacheRowsShown = 10

    func run() async throws {
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
        print("This is a listing only — nothing has been deleted. Deletion support lands in a later version.")
    }
}
