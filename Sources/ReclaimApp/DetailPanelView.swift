import SwiftUI
import AppKit
import ReclaimKit

/// The single window-style detail panel behind the menu bar icon. Stock SwiftUI controls
/// only — no custom glass/vibrancy layers, no custom popover chrome (locked UI-style decision,
/// docs/IMPLEMENTATION.md).
struct DetailPanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                Divider()

                if let detected = appState.detected {
                    breakdownSection(backend: detected)
                    Divider()
                    controlsSection
                    if !appState.logLines.isEmpty {
                        ProgressLogView(lines: appState.logLines)
                    }
                    if let report = appState.lastReport {
                        resultSection(report: report)
                    }
                } else {
                    startColimaSection
                }

                Divider()
                HistorySectionView()
                Divider()
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "internaldrive")
                Text("Reclaim").font(.title3.weight(.bold))
                Spacer()
                if appState.isRefreshing {
                    ProgressView().controlSize(.small)
                }
            }

            if let stat = appState.diskStat {
                Text("\(formatBytes(stat.freeBytes)) free of \(formatBytes(stat.totalBytes))")
                    .font(.subheadline)
            } else {
                Text("Reading disk usage…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let backend = appState.detected {
                Text("Backend: \(backend.backend.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Breakdown

    private func breakdownSection(backend: DetectedBackend) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Docker usage").font(.headline)

            if let df = appState.diskUsage {
                // Build Cache first — it's usually the big one (SPEC.md §7).
                BreakdownCardView(
                    title: "Build Cache",
                    systemImage: "shippingbox.fill",
                    total: df.buildCacheTotalSize,
                    reclaimable: df.buildCacheReclaimableSize
                )
                BreakdownCardView(
                    title: "Images",
                    systemImage: "photo.stack",
                    total: df.imagesTotalSize,
                    reclaimable: df.imagesReclaimableSize
                )
                BreakdownCardView(
                    title: "Containers",
                    systemImage: "shippingbox",
                    total: df.stoppedContainersSize,
                    reclaimable: df.stoppedContainersSize,
                    subtitle: "\(df.stoppedContainersCount) stopped"
                )
                BreakdownCardView(
                    title: "Volumes",
                    systemImage: "lock.fill",
                    total: df.volumesTotalSize,
                    reclaimable: 0,
                    subtitle: "\(df.volumesCount) volumes",
                    isProtected: true
                )

                if !df.volumes.isEmpty {
                    protectedVolumesBanner(volumes: df.volumes)
                }
            } else {
                ProgressView("Reading Docker usage…")
            }
        }
    }

    private func protectedVolumesBanner(volumes: [Volume]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Label("Protected volumes — never touched by Reclaim", systemImage: "lock.shield")
                    .font(.caption.bold())
                ForEach(volumes, id: \.name) { volume in
                    HStack {
                        Text("\u{1F512} \(volume.name)")
                        Spacer()
                        if let size = volume.usageSize, size >= 0 {
                            Text(formatBytes(size)).foregroundStyle(.secondary)
                        } else {
                            Text("size unknown").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Preview (dry run)", isOn: $appState.previewMode)
                .disabled(appState.isCleaning)

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

            if appState.showSlowBuildNote {
                Label(
                    "Next build may be slower while the build cache rebuilds.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var buttonTitle: String {
        if appState.isCleaning {
            return appState.previewMode ? "Previewing…" : "Reclaiming…"
        }
        return appState.previewMode ? "Preview" : "Reclaim"
    }

    // MARK: - Result

    private func resultSection(report: CleanReport) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if report.dryRun {
                    let estimated = report.steps.reduce(Int64(0)) { $0 + $1.dockerReportedBytes }
                    Text("Would reclaim roughly \(formatBytes(estimated))")
                        .font(.subheadline.weight(.semibold))
                    Text("Docker's own estimate — turn off Preview to see the real number.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(formatBytes(report.hostDelta)) returned to macOS")
                        .font(.headline)
                    Text("Host free: \(formatBytes(report.hostFreeBefore)) \u{2192} \(formatBytes(report.hostFreeAfter))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let note = report.trimNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start Colima

    private var startColimaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No Docker backend detected", systemImage: "exclamationmark.triangle")
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
                    Text(appState.isStartingColima ? "Starting Colima…" : "Start Colima")
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
        HStack {
            Button("Refresh") {
                Task { await appState.refresh() }
            }
            Spacer()
            Button("Quit Reclaim") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
