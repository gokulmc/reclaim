import SwiftUI
import AppKit
import ReclaimKit

/// The single window-style detail panel behind the menu bar icon. Stock SwiftUI controls
/// only — no custom glass/vibrancy layers, no custom popover chrome (locked UI-style decision,
/// docs/IMPLEMENTATION.md). Layout and copy follow the approved redesign in
/// docs/design/panel.html and docs/design/copy.html: one plain-language junk number instead of
/// the old four-card Docker breakdown, "Show me first" instead of "Preview (dry run)", and a
/// green "Your data is safe" strip instead of a raw volumes table.
struct DetailPanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                Divider()

                if appState.detected != nil {
                    if let df = appState.diskUsage {
                        heroJunkCard(df: df)
                        controlsSection
                        if let report = appState.lastReport {
                            resultSection(report: report)
                        }
                        if !appState.logLines.isEmpty {
                            ProgressLogView(lines: appState.logLines)
                        }
                        Divider()
                        safetyStrip(df: df)
                    } else {
                        ProgressView("Checking what Docker is sitting on…")
                    }
                } else {
                    startColimaSection
                }

                Divider()
                HistorySectionView()
                SchedulingSectionView()

                Divider()
                footerSection
            }
            .padding(16)
        }
        .frame(width: 380)
        .frame(minHeight: 240, maxHeight: 640)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(nsImage: MenuBarIcon.image(tint: nil))
                Text("Reclaim").font(.title3.weight(.bold))
                Spacer()
                if appState.isRefreshing {
                    ProgressView().controlSize(.small)
                }
            }

            if let stat = appState.diskStat {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(appFormatBytes(stat.freeBytes))
                        .font(.title2.weight(.bold))
                    Text("free on your Mac")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: usedFraction(stat: stat))
                    .tint(.accentColor)
            } else {
                Text("Checking your disk…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func usedFraction(stat: DiskStat) -> Double {
        guard stat.totalBytes > 0 else { return 0 }
        let used = Double(stat.totalBytes - stat.freeBytes)
        return min(max(used / Double(stat.totalBytes), 0), 1)
    }

    // MARK: - Hero junk card

    /// Replaces the old four-card Docker breakdown (Build Cache / Images / Containers /
    /// Volumes) with one plain sentence and one number; the technical split moves behind
    /// "What exactly?" (docs/design/copy.html).
    private func heroJunkCard(df: DiskUsage) -> some View {
        // Build cache + images only — containers aren't counted here because pruning them is
        // off by default (see `totalMappedSteps` in AppState) and the headline number should
        // match what the CTA button below is actually about to reclaim.
        let junkBytes = df.buildCacheReclaimableSize + df.imagesReclaimableSize

        return VStack(alignment: .leading, spacing: 6) {
            Text("Docker is sitting on ≈ \(appFormatBytes(junkBytes)) of junk")
                .font(.subheadline.weight(.semibold))
            Text("Old build leftovers and unused downloads. Safe to clear — Docker recreates anything it needs later.")
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("What exactly?") {
                VStack(alignment: .leading, spacing: 4) {
                    breakdownRow(label: "Build leftovers", value: df.buildCacheReclaimableSize)
                    breakdownRow(label: "Unused app images", value: df.imagesReclaimableSize)
                    breakdownRow(label: "Finished containers", value: df.stoppedContainersSize)
                }
                .padding(.top, 2)
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.1)))
    }

    private func breakdownRow(label: String, value: Int64) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(appFormatBytes(value)).monospacedDigit()
        }
    }

    // MARK: - Controls (CTA + "Show me first")

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                appState.runClean()
            } label: {
                HStack {
                    if appState.isCleaning {
                        ProgressView().controlSize(.small)
                    }
                    Text(buttonTitle)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isCleaning)

            Toggle(isOn: $appState.previewMode) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show me first")
                    Text(toggleCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(appState.isCleaning)
        }
    }

    /// Button text follows the toggle (docs/design/copy.html: "[ Preview ] / [ Reclaim ]" →
    /// "[ See what I'd get back ] / [ Get my space back ]").
    private var buttonTitle: String {
        if appState.isCleaning {
            return appState.previewMode ? "Checking what you’d get back…" : "Getting your space back…"
        }
        return appState.previewMode ? "See what I’d get back" : "Get my space back"
    }

    private var toggleCaption: String {
        appState.previewMode
            ? "Nothing is deleted until you turn this off and run it again."
            : "Off — the next run cleans for real."
    }

    // MARK: - Result

    private func resultSection(report: CleanReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if report.dryRun {
                let estimated = report.steps.reduce(Int64(0)) { $0 + $1.dockerReportedBytes }
                Text("You’d get back about \(appFormatBytes(estimated))")
                    .font(.subheadline.weight(.semibold))
                Text("Estimate — the real, measured number is shown after a cleanup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("🎉 \(appFormatBytes(report.hostDelta)) returned to your Mac")
                    .font(.headline)
                Text("Free space went \(appFormatBytes(report.hostFreeBefore)) \u{2192} \(appFormatBytes(report.hostFreeAfter)). That’s the real number, measured on your disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(report.dryRun ? Color.secondary.opacity(0.08) : Color.green.opacity(0.14))
        )
    }

    // MARK: - Safety strip

    /// Replaces the old "Volumes" breakdown card + protected-volumes `GroupBox` list with a
    /// green "Your data is safe" strip; the volume names/sizes move behind a small
    /// `DisclosureGroup` inside it so they're still reachable (docs/design/copy.html).
    private func safetyStrip(df: DiskUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Your data is safe", systemImage: "lock.fill")
                .font(.caption.weight(.semibold))
            Text(safetyCaption(count: df.volumesCount))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !df.volumes.isEmpty {
                DisclosureGroup("Which volumes?") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(df.volumes, id: \.name) { volume in
                            HStack {
                                Text(volume.name)
                                Spacer()
                                if let size = volume.usageSize, size >= 0 {
                                    Text(appFormatBytes(size)).foregroundStyle(.secondary)
                                } else {
                                    Text("size unknown").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .font(.caption2)
                    .padding(.top, 2)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.10)))
    }

    private func safetyCaption(count: Int) -> String {
        let plural = count == 1 ? "volume" : "volumes"
        if let report = appState.lastReport, !report.dryRun {
            return "\(count) data \(plural) untouched, as always."
        }
        return "\(count) data \(plural) (databases, project files) are read-only to Reclaim. "
            + "It has no delete button for them — by design."
    }

    // MARK: - Start Colima

    private var startColimaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Docker isn’t running", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text("Colima, OrbStack, Rancher Desktop, and Docker Desktop were all unreachable.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                appState.startColima()
            } label: {
                HStack {
                    if appState.isStartingColima {
                        ProgressView().controlSize(.small)
                    }
                    Text(appState.isStartingColima ? "Starting Docker (Colima)…" : "Start Docker (Colima)")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isStartingColima)

            if !appState.logLines.isEmpty {
                ProgressLogView(lines: appState.logLines)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Refresh") {
                    Task { await appState.refresh() }
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            if !finePrint.isEmpty {
                Text(finePrint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Backend name moves here from the header (docs/design/copy.html: "Watching: Colima ...
    /// laymen don't need it above the fold"), joined with the one-time slow-build note when
    /// applicable.
    private var finePrint: String {
        var parts: [String] = []
        if let backend = appState.detected {
            parts.append("Watching: \(backend.backend.displayName)")
        }
        if appState.showSlowBuildNote {
            parts.append("First Docker build after a cleanup can be slower while Docker warms back up.")
        }
        return parts.joined(separator: " · ")
    }
}
