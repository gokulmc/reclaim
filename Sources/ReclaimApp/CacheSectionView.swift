import SwiftUI
import ReclaimKit

/// The read-only "Dev tool caches" section (M1 of docs/plan expressive-conjuring-pelican.md,
/// matching docs/design/caches-section.html). Purely additive: a single `DisclosureGroup`,
/// **collapsed by default**, appended below the Docker block so the panel's at-rest
/// appearance is unchanged for existing users.
///
/// Read-only on purpose — no checkboxes, no delete action. `CacheDeleter`/`CacheSafetyGuard`
/// (the actual safety gate) land in a later milestone before any button appears here.
struct CacheSectionView: View {
    /// Every cache `AppState.refresh()` scanned via `CacheScanner` — both the single-directory
    /// tool caches and the per-app `~/Library/Caches` children, unfiltered/unsorted.
    let caches: [ScannedCache]

    /// `CacheCatalog`'s per-app source; matches `CacheScanner`'s own per-app `definitionID`.
    private static let libraryCachesID = "library-caches"

    /// Mirrors `CachesCommand.maxAppCacheRowsShown` (Sources/reclaim-cli/CachesCommand.swift)
    /// so the CLI's `caches` listing and this app section agree on how many of the largest
    /// per-app rows to show before summarizing the rest.
    private static let maxAppCacheRowsShown = 10

    /// `CacheCatalog.default()` is a static in-memory list (no disk IO), so it's cheap to
    /// build a description lookup here rather than threading catalog descriptions through
    /// `ScannedCache` itself.
    private static let definitionsByID: [String: CacheDefinition] =
        Dictionary(uniqueKeysWithValues: CacheCatalog.default().map { ($0.id, $0) })

    /// Single-directory tool caches (npm, Xcode DerivedData, Homebrew, ...) — everything that
    /// isn't the per-app `~/Library/Caches` fan-out. Absent/empty caches are skipped.
    private var singleDirectoryCaches: [ScannedCache] {
        caches
            .filter { $0.definitionID != Self.libraryCachesID && $0.sizeBytes > 0 }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// The per-app `~/Library/Caches` children, largest first.
    private var appCaches: [ScannedCache] {
        caches
            .filter { $0.definitionID == Self.libraryCachesID && $0.sizeBytes > 0 }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private var totalBytes: Int64 {
        caches.reduce(0) { $0 + $1.sizeBytes }
    }

    private var appCachesTotalBytes: Int64 {
        appCaches.reduce(0) { $0 + $1.sizeBytes }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                Text("What each tool caches — safe to clear later")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11)
                    .padding(.top, 4)
                    .padding(.bottom, 2)

                ForEach(singleDirectoryCaches) { cache in
                    ItemRow(
                        emoji: emoji(for: cache.definitionID),
                        chipTint: chipTint(for: cache.definitionID),
                        name: cache.displayName,
                        description: description(for: cache.definitionID),
                        size: cache.sizeBytes,
                        tagText: "CLEANABLE",
                        tagForeground: Palette.tagCleanableFG,
                        tagBackground: Palette.tagCleanableBG
                    )
                }

                if !appCaches.isEmpty {
                    appCachesDisclosure
                }
            }
        } label: {
            HStack {
                Text("Dev tool caches")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(appFormatBytes(totalBytes))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
    }

    /// The nested per-app fan-out of `~/Library/Caches` — the "app-wise" view from the plan
    /// (each subdirectory sized individually, never one blob). Simple name + size rows, no
    /// chips/tags (this mirrors the design card's `.app` rows, which are visually lighter than
    /// the top-level tool rows since there can be dozens of them).
    private var appCachesDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(appCaches.prefix(Self.maxAppCacheRowsShown))) { cache in
                    HStack {
                        Text(cache.displayName)
                            .font(.system(size: 12))
                        Spacer()
                        Text(appFormatBytes(cache.sizeBytes))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.leading, 26)
                    .padding(.trailing, 4)
                    .padding(.vertical, 3)
                }

                let shown = min(appCaches.count, Self.maxAppCacheRowsShown)
                let remaining = appCaches.count - shown
                if remaining > 0 {
                    Text("+ \(remaining) smaller…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)
                        .padding(.top, 2)
                        .padding(.bottom, 2)
                }
            }
            .padding(.top, 2)
        } label: {
            HStack {
                Text("App caches (~/Library/Caches)")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(appFormatBytes(appCachesTotalBytes))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.leading, 14)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    /// Sensible, SF-Symbol-free chips per tool (docs/design/caches-section.html `.chip`).
    /// Unlisted/future catalog entries fall back to a plain folder — this never needs updating
    /// just because `CacheCatalog` grows an entry it doesn't specifically style.
    private func emoji(for definitionID: String) -> String {
        switch definitionID {
        case "npm", "pnpm", "yarn": return "📦"
        case "xcode-derived-data": return "🔨"
        case "homebrew": return "🍺"
        case "gradle": return "🐘"
        case "pip": return "🐍"
        case "cocoapods": return "💎"
        default: return "🗂️"
        }
    }

    /// Matches the design card's chip backgrounds: Xcode blue (`Palette.buildCache`), Homebrew
    /// amber (`Palette.containers`), everything else the default purple (`Palette.images`,
    /// `#5e5ce6` — exactly the design's `.chip` default background).
    private func chipTint(for definitionID: String) -> Color {
        switch definitionID {
        case "xcode-derived-data": return Palette.buildCache
        case "homebrew": return Palette.containers
        default: return Palette.images
        }
    }

    private func description(for definitionID: String) -> String {
        Self.definitionsByID[definitionID]?.description ?? ""
    }
}
