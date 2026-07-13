import SwiftUI
import ReclaimKit

/// The interactive "Dev tool caches" section (M3b of docs/plan expressive-conjuring-pelican.md,
/// matching docs/design/caches-section.html's expanded card). Purely additive: a single
/// `DisclosureGroup`, **collapsed by default**, appended below the Docker block so the panel's
/// at-rest appearance is unchanged for existing users (M1's read-only shape).
///
/// M3b adds selection + a self-contained clean flow on top of M1's read-only rows: checkboxes
/// (`SelectableItemRow`/`SelectableAppCacheRow`) bound to `AppState.selectedCacheIDs`, "Select
/// all safe", "Clean selected", and its own progress log + result line — all rendered inside
/// this view, never touching the Docker CTA's `logLines`/`lastReport`.
struct CacheSectionView: View {
    /// Every cache `AppState.refresh()` scanned via `CacheScanner` — both the single-directory
    /// tool caches and the per-app `~/Library/Caches` children, unfiltered/unsorted.
    let caches: [ScannedCache]

    /// Selection state and the clean action both live on `AppState` (M3b) so they survive this
    /// view being recreated/collapsed, and so `cleanSelectedCaches()` can run independent of
    /// this view's lifetime. Supplied via the environment (set once at the app root in
    /// `ReclaimApp.swift`) — `DetailPanelView`'s `CacheSectionView(caches:)` call site is
    /// unchanged.
    @EnvironmentObject var appState: AppState

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

    /// Sum of sizes for every currently-ticked id (single-dir tools + per-app children alike).
    private var selectedBytes: Int64 {
        caches
            .filter { appState.selectedCacheIDs.contains($0.id) }
            .reduce(0) { $0 + $1.sizeBytes }
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
                    SelectableItemRow(
                        isOn: selectionBinding(for: cache.id),
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

                if !caches.isEmpty {
                    Divider().padding(.horizontal, 11).padding(.top, 4)
                    actionBar
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
    /// (each subdirectory sized individually, never one blob). Simple name + size rows (each
    /// its own checkbox), no chips/tags (this mirrors the design card's `.app` rows, which are
    /// visually lighter than the top-level tool rows since there can be dozens of them).
    private var appCachesDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(appCaches.prefix(Self.maxAppCacheRowsShown))) { cache in
                    SelectableAppCacheRow(
                        isOn: selectionBinding(for: cache.id),
                        name: cache.displayName,
                        size: cache.sizeBytes
                    )
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

    // MARK: - Selection + clean action bar (M3b, `.bar` in the design card)

    /// "Select all safe" + the "N selected · ≈ X" summary, the "Clean selected" CTA, the shared
    /// "Show me first" toggle, and — self-contained, inside this section — this run's own
    /// progress log + result line. Nothing here touches `AppState.logLines`/`lastReport`, the
    /// Docker CTA's state.
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    appState.selectAllSafeCaches()
                } label: {
                    Text("Select all safe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ctaFill)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(selectionSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button {
                appState.cleanSelectedCaches()
            } label: {
                HStack(spacing: 6) {
                    if appState.isCleaningCaches {
                        ProgressView().controlSize(.small)
                    }
                    Text(cleanButtonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CTAButtonStyle())
            .disabled(appState.isCleaningCaches || appState.selectedCacheIDs.isEmpty)

            Toggle(isOn: $appState.previewMode) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show me first")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(previewToggleCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(appState.isCleaningCaches)

            if !appState.cacheLogLines.isEmpty {
                ProgressLogView(lines: appState.cacheLogLines)
            }

            if let report = appState.cacheReport {
                cacheResultLine(report: report)
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var selectionSummary: String {
        "\(appState.selectedCacheIDs.count) selected \u{00B7} \u{2248} \(appFormatBytes(selectedBytes))"
    }

    /// Follows the "Show me first" toggle, same as the Docker CTA's button
    /// (docs/design/copy.html): "[ Preview ] / [ Reclaim ]" → "[ See what I'd get back ] /
    /// [ Get my space back ]", worded here for caches specifically.
    private var cleanButtonTitle: String {
        appState.previewMode ? "See what I\u{2019}d free" : "Free selected space"
    }

    private var previewToggleCaption: String {
        appState.previewMode
            ? "Nothing is deleted until you turn this off and run it again."
            : "Off — the next run cleans for real."
    }

    private func cacheResultLine(report: CleanReport) -> some View {
        Group {
            if report.dryRun {
                let estimated = report.steps.reduce(Int64(0)) { $0 + $1.dockerReportedBytes }
                resultText(
                    "You\u{2019}d free \u{2248} \(appFormatBytes(estimated))",
                    tint: Color.secondary.opacity(0.08)
                )
            } else {
                resultText(
                    "\u{1F389} \(appFormatBytes(report.hostDelta)) freed",
                    tint: Color.green.opacity(0.14)
                )
            }
        }
    }

    private func resultText(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint))
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { appState.selectedCacheIDs.contains(id) },
            set: { _ in appState.toggleCacheSelection(id) }
        )
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
