import SwiftUI
import AppKit
import ReclaimKit

/// The "Large files & folders" danger zone (M-LF8, matching
/// docs/design/large-files-section.html's expanded card). Purely additive, cloned from
/// `CacheSectionView`'s shape (a single `DisclosureGroup`, **collapsed by default**): FDA
/// banner, scan/cancel, a ranked merged list of files+folders with protected rows locked, a
/// select/clear + move-to-Trash action bar, a dedicated preview toggle + confirmation alert, and
/// its own self-contained progress log + result line. The one structural difference from every
/// other section — the whole point of this milestone — is the content's full-width
/// `Palette.dangerZoneBackground` band, marking this as the app's first feature that can delete
/// arbitrary (potentially irreplaceable) user files.
///
/// All state lives on `AppState` (`largeItems`, `selectedLargeItemIDs`, `largeFilesLog`,
/// `largeFilesReport`, ...) and is entirely self-contained: nothing here reads or writes the
/// Docker CTA's `logLines`/`lastReport` or the dev-tool cache flow's `cacheLogLines`/
/// `cacheReport`.
struct LargeFilesSectionView: View {
    @EnvironmentObject var appState: AppState

    /// Mirrors `CacheSectionView.maxAppCacheRowsShown`'s "show the biggest N, summarize the
    /// rest" convention for a section that can otherwise fan out into hundreds of candidates.
    private static let maxRowsShown = 15

    private var totalBytes: Int64 {
        appState.largeItems.reduce(0) { $0 + $1.sizeBytes }
    }

    private var selectedBytes: Int64 {
        appState.largeItems
            .filter { appState.selectedLargeItemIDs.contains($0.id) }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    private var shownItems: [LargeItem] {
        Array(appState.largeItems.prefix(Self.maxRowsShown))
    }

    private var remainingCount: Int {
        max(appState.largeItems.count - Self.maxRowsShown, 0)
    }

    private var needsFullDiskAccessBanner: Bool {
        appState.largeFilesNeedsFullDiskAccess || !appState.largeFilesSkippedAreas.isEmpty
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                Text("The biggest files & folders in your home. Selected items move to the Trash \u{2014} recoverable.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11)
                    .padding(.top, 4)
                    .padding(.bottom, 2)

                if needsFullDiskAccessBanner {
                    fdaBanner
                }

                if appState.isScanningLargeFiles {
                    scanningRow
                } else if appState.largeItems.isEmpty {
                    scanButton
                } else {
                    ForEach(shownItems) { item in
                        row(item)
                    }

                    if remainingCount > 0 {
                        Text("+ \(remainingCount) smaller\u{2026}")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 40)
                            .padding(.top, 2)
                            .padding(.bottom, 2)
                    }

                    Divider().padding(.horizontal, 11).padding(.top, 4)
                    actionBar
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            headerLabel
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        // The whole point of this milestone: a full-width distinct "danger zone" band behind
        // the entire section — label included — so it reads as different-from-everything-else
        // even when collapsed (not only once expanded).
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.dangerZoneBackground)
        .alert(
            "Move \(appState.selectedLargeItemIDs.count) item(s) (~\(appFormatBytes(selectedBytes))) to the Trash?",
            isPresented: $appState.showLargeFilesTrashConfirmation
        ) {
            Button("Move to Trash", role: .destructive) {
                appState.moveSelectedToTrash(dryRun: appState.largeFilesPreviewMode)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Recoverable \u{2014} restore from the Trash anytime.")
        }
    }

    // MARK: - Label (`.zhead` in the design card)

    private var headerLabel: some View {
        HStack(spacing: 7) {
            Text("Large files & folders")
                .font(.system(size: 12.5, weight: .semibold))

            Text("HIGHER-RISK")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(Palette.dangerAccentFG)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Palette.dangerAccentFG.opacity(0.2)))

            Spacer()

            if !appState.largeItems.isEmpty {
                Text(appFormatBytes(totalBytes))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Full Disk Access banner (`.fda`)

    private var fdaBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Some areas were skipped (Desktop, Documents, iCloud\u{2026}). Grant Full Disk Access to include them.")
                .font(.system(size: 11))

            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            } label: {
                Text("Open Full Disk Access settings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ctaFill)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.dangerAccentFG.opacity(0.15)))
        .padding(.horizontal, 11)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    // MARK: - Idle / scanning states (`.scanbtn` / `.prog`)

    private var scanButton: some View {
        Button {
            appState.startLargeFileScan()
        } label: {
            Text("Scan home for large files")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(CTAButtonStyle())
        .padding(.horizontal, 11)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private var scanningRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(scanningText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                appState.cancelLargeFileScan()
            } label: {
                Text("Cancel")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ctaFill)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private var scanningText: String {
        guard let progress = appState.largeScanProgress else { return "Scanning\u{2026}" }
        return "Scanned \(progress.filesScanned) files \u{00B7} \(progress.currentArea)\u{2026}"
    }

    // MARK: - Rows (`.row`) — modeled on `DetailPanelView.imageRow(_:)`

    /// A leading `CacheCheckbox` for a selectable item, or a `lock.fill` glyph for a protected
    /// one (never selectable — `FileTrashGuard` already rejected it, stamped as
    /// `LargeItem.isProtected` by the scanner). A folder/file SF Symbol, a home-relativized
    /// monospaced path (single line, middle-truncated so both the leading area and the trailing
    /// filename stay visible), and the size.
    private func row(_ item: LargeItem) -> some View {
        HStack(spacing: 9) {
            if item.isSelectable {
                CacheCheckbox(isOn: selectionBinding(for: item.id))
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }

            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 15)

            Text(homeRelative(item.path))
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(appFormatBytes(item.sizeBytes))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(item.isSelectable ? .primary : .secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 3)
        .opacity(item.isSelectable ? 1 : 0.5)
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { appState.selectedLargeItemIDs.contains(id) },
            set: { _ in appState.toggleLargeItemSelection(id) }
        )
    }

    /// Renders an absolute path under `$HOME` as `~/...`; matches
    /// `LargeFilesCommand.homeRelative(_:)` in the CLI so the two surfaces agree.
    private func homeRelative(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Selection + move-to-Trash action bar (`.bar`)

    /// "Clear" + the "N selected · ≈ X" summary, the `CTAButtonStyle` move-to-Trash button
    /// (which only *arms the confirmation alert* — the real move happens from
    /// `moveSelectedToTrash(dryRun:)` in the alert's destructive action), the dedicated "Show me
    /// first" preview toggle, and — self-contained, inside this section — this run's own
    /// progress log + result line.
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    appState.clearLargeSelection()
                } label: {
                    Text("Clear")
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
                appState.requestTrashSelected()
            } label: {
                HStack(spacing: 6) {
                    if appState.isTrashingLargeFiles {
                        ProgressView().controlSize(.small)
                    }
                    Text(trashButtonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CTAButtonStyle())
            .disabled(appState.isTrashingLargeFiles || appState.selectedLargeItemIDs.isEmpty)

            Toggle(isOn: $appState.largeFilesPreviewMode) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show me first")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Nothing moves until you turn this off and confirm.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(appState.isTrashingLargeFiles)

            if !appState.largeFilesLog.isEmpty {
                ProgressLogView(lines: appState.largeFilesLog)
            }

            if let report = appState.largeFilesReport {
                resultLine(report: report)
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var selectionSummary: String {
        "\(appState.selectedLargeItemIDs.count) selected \u{00B7} \u{2248} \(appFormatBytes(selectedBytes))"
    }

    private var trashButtonTitle: String {
        appState.largeFilesPreviewMode ? "See what I\u{2019}d move" : "Move selected to Trash"
    }

    private func resultLine(report: CleanReport) -> some View {
        Group {
            if report.dryRun {
                let estimated = report.steps.reduce(Int64(0)) { $0 + $1.dockerReportedBytes }
                resultText(
                    "You\u{2019}d free \u{2248} \(appFormatBytes(estimated))",
                    tint: Color.secondary.opacity(0.08)
                )
            } else {
                resultText(
                    "\u{1F389} \(appFormatBytes(report.hostDelta)) moved to Trash",
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
}
