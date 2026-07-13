import SwiftUI
import AppKit
import ReclaimKit

/// The single window-style detail panel behind the menu bar icon. Stock SwiftUI controls
/// only — no custom glass/vibrancy layers, no custom popover chrome (locked UI-style decision,
/// docs/IMPLEMENTATION.md; the `MenuBarExtra(.window)` style already provides the panel's own
/// material). Layout, hierarchy, spacing, and token values follow the approved v4 redesign in
/// docs/design/panel.html: a rounded hero free-space figure, a health pill driven by the same
/// `DiskLevel` thresholds as the menu bar icon, a Docker-footprint stack-bar with legend, and
/// itemised "Safe to clear" / "Protected — never touched" rows with CLEANABLE/SAFE/NONE tags.
struct DetailPanelView: View {
    @EnvironmentObject var appState: AppState

    private let panelWidth: CGFloat = 320

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection

                if appState.detected != nil {
                    if let df = appState.diskUsage {
                        // Primary action first, above the fold — the whole point of the app is
                        // one click, so the Reclaim button must be visible without scrolling.
                        // The itemised breakdown follows as supporting detail.
                        divider
                        ctaSection(df: df)

                        if let report = appState.lastReport {
                            resultSection(report: report)
                        }
                        if !appState.logLines.isEmpty {
                            ProgressLogView(lines: appState.logLines)
                                .padding(.horizontal, 11)
                                .padding(.top, 6)
                                .padding(.bottom, 8)
                        }

                        divider
                        itemizedSections(df: df)
                    } else {
                        ProgressView("Checking what Docker is sitting on…")
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    divider
                    startColimaSection
                        .padding(11)
                }

                // Dev-tool caches (M1, docs/design/caches-section.html) — backend-independent,
                // so this renders even when Docker/Colima is down. Purely additive: collapsed
                // by default, wrapped in the same `divider` used everywhere else in this view.
                divider
                CacheSectionView(caches: appState.caches)

                divider
                VStack(alignment: .leading, spacing: 10) {
                    HistorySectionView()
                    SchedulingSectionView()
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)

                divider
                footerSection
            }
        }
        .frame(width: panelWidth)
        .frame(minHeight: 240, maxHeight: 640)
    }

    private var divider: some View {
        Divider().padding(.horizontal, 11)
    }

    // MARK: - Header (`.header`: brand + hero + subline + health pill + footprint stack-bar)

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    brandRow
                    heroRow.padding(.top, 9)
                    sublineRow.padding(.top, 5)
                }
                Spacer(minLength: 8)
                HealthPill(level: appState.diskLevel)
            }

            if let df = appState.diskUsage {
                footprintBlock(df: df).padding(.top, 14)
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 11)
        .padding(.bottom, 12)
    }

    private var brandRow: some View {
        HStack(spacing: 6) {
            Image(nsImage: MenuBarIcon.image(tint: nil))
                .resizable()
                .renderingMode(.template)
                .frame(width: 15, height: 15)
            Text("Reclaim")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.secondary)
    }

    private var heroRow: some View {
        Group {
            if let stat = appState.diskStat {
                let split = appFormatBytesSplit(stat.freeBytes)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(split.value)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .tracking(-0.5)
                        .monospacedDigit()
                    Text("\(split.unit) free")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Checking your disk…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Idle: "of 460 GB · 88% used". After a real (non-preview) run: "+12.4 GB just returned ·
    /// 41.3 → 53.7" (docs/design/panel.html, dark "after a run" mockup).
    private var sublineRow: some View {
        Group {
            if let report = appState.lastReport, !report.dryRun {
                (
                    Text("+\(appFormatBytes(report.hostDelta)) ")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    + Text("just returned · ")
                    + Text("\(appFormatBytes(report.hostFreeBefore)) \u{2192} \(appFormatBytes(report.hostFreeAfter))")
                        .monospacedDigit()
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            } else if let stat = appState.diskStat {
                (
                    Text("of ")
                    + Text(appFormatBytes(stat.totalBytes)).fontWeight(.semibold).monospacedDigit()
                    + Text(" \u{00B7} ")
                    + Text("\(usedPercent(stat: stat))%").fontWeight(.semibold).monospacedDigit()
                    + Text(" used")
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func usedFraction(stat: DiskStat) -> Double {
        guard stat.totalBytes > 0 else { return 0 }
        let used = Double(stat.totalBytes - stat.freeBytes)
        return min(max(used / Double(stat.totalBytes), 0), 1)
    }

    private func usedPercent(stat: DiskStat) -> Int {
        Int((usedFraction(stat: stat) * 100).rounded())
    }

    // MARK: - Docker footprint stack-bar (`.foot-hd` + `.stackbar` + `.legend`)

    private func footprintBlock(df: DiskUsage) -> some View {
        let total = df.buildCacheTotalSize + df.imagesTotalSize + df.stoppedContainersSize + df.volumesTotalSize
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Docker is using")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(appFormatBytes(total))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }

            StackBarView(segments: [
                StackBarSegment(color: Palette.buildCache, value: df.buildCacheTotalSize),
                StackBarSegment(color: Palette.images, value: df.imagesTotalSize),
                StackBarSegment(color: Palette.containers, value: df.stoppedContainersSize),
                StackBarSegment(color: Palette.yourData, value: df.volumesTotalSize)
            ])

            FootprintLegend(items: legendItems(df: df))
        }
    }

    /// Only non-zero categories are shown — this naturally hides "Containers" whenever there
    /// are no stopped containers, per the design ("include Containers only if > 0").
    private func legendItems(df: DiskUsage) -> [FootprintLegendItem] {
        [
            FootprintLegendItem(color: Palette.buildCache, name: "Build cache", value: df.buildCacheTotalSize),
            FootprintLegendItem(color: Palette.images, name: "Images", value: df.imagesTotalSize),
            FootprintLegendItem(color: Palette.containers, name: "Containers", value: df.stoppedContainersSize),
            FootprintLegendItem(color: Palette.yourData, name: "Your data", value: df.volumesTotalSize)
        ].filter { $0.value > 0 }
    }

    // MARK: - Itemised rows (`.sect` + `.row`)

    private func itemizedSections(df: DiskUsage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Safe to clear")

            ItemRow(
                emoji: "🧱",
                chipTint: Palette.buildCache,
                name: "Build leftovers",
                description: "Scraps from building images — rebuilt automatically",
                size: df.buildCacheReclaimableSize,
                tagText: df.buildCacheReclaimableSize > 0 ? "CLEANABLE" : "NONE",
                tagForeground: df.buildCacheReclaimableSize > 0 ? Palette.tagCleanableFG : Palette.tagNoneFG,
                tagBackground: df.buildCacheReclaimableSize > 0 ? Palette.tagCleanableBG : Palette.tagNoneBG
            )
            ItemRow(
                emoji: "📦",
                chipTint: Palette.images,
                name: "Unused app images",
                description: "Downloads nothing is running right now",
                size: df.imagesReclaimableSize,
                tagText: df.imagesReclaimableSize > 0 ? "CLEANABLE" : "NONE",
                tagForeground: df.imagesReclaimableSize > 0 ? Palette.tagCleanableFG : Palette.tagNoneFG,
                tagBackground: df.imagesReclaimableSize > 0 ? Palette.tagCleanableBG : Palette.tagNoneBG
            )

            // Opt-in, collapsed-by-default disclosure (M4b, docs/design/docker-image-selection.html):
            // purely additive under the "Unused app images" row above — collapsed, the Docker
            // breakdown is byte-for-byte what it was before this milestone.
            if !df.images.isEmpty {
                imageSelectionDisclosure(df: df)
            }

            ItemRow(
                emoji: "⏹️",
                chipTint: Palette.containers,
                name: "Finished containers",
                description: "Programs that already exited",
                size: df.stoppedContainersSize,
                tagText: df.stoppedContainersCount > 0 ? "\(df.stoppedContainersCount)" : "NONE",
                tagForeground: df.stoppedContainersCount > 0 ? Palette.tagCleanableFG : Palette.tagNoneFG,
                tagBackground: df.stoppedContainersCount > 0 ? Palette.tagCleanableBG : Palette.tagNoneBG
            )

            divider
            sectionLabel("Protected — never touched")

            VStack(alignment: .leading, spacing: 0) {
                ItemRow(
                    emoji: "🔒",
                    chipTint: Palette.yourData,
                    name: "Your data",
                    description: "\(df.volumesCount) volume\(df.volumesCount == 1 ? "" : "s") — databases & project files",
                    size: df.volumesTotalSize,
                    tagText: "SAFE",
                    tagForeground: Palette.tagSafeFG,
                    tagBackground: Palette.tagSafeBG
                )

                if !df.volumes.isEmpty {
                    DisclosureGroup("Which volumes?") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(df.volumes, id: \.name) { volume in
                                HStack {
                                    Text(volume.name)
                                    Spacer()
                                    if let size = volume.usageSize, size >= 0 {
                                        Text(appFormatBytes(size))
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
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
                    .padding(.horizontal, 11)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    // MARK: - Docker per-image selection (M4b, `.disc`/`.img`/`.bar` in
    // docs/design/docker-image-selection.html)

    /// The opt-in "Remove specific images…" disclosure, collapsed by default (SwiftUI's
    /// `DisclosureGroup` default state), inserted directly under the "Unused app images"
    /// `ItemRow` above. A small blue-accent caption label — matching the design card's `.disc`
    /// style, reusing the same tint `ItemRow`'s CLEANABLE tag already uses — nothing else in
    /// `itemizedSections` changes shape or order.
    private func imageSelectionDisclosure(df: DiskUsage) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(df.images.sorted { $0.size > $1.size }, id: \.id) { image in
                    imageRow(image)
                }

                Text("In-use or multi-tagged images are skipped automatically — your running stack is never broken.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
                    .padding(.trailing, 11)
                    .padding(.top, 2)
                    .padding(.bottom, 4)

                imageActionBar(df: df)
            }
            .padding(.top, 2)
        } label: {
            Text("Remove specific images…")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.tagCleanableFG)
        }
        .padding(.horizontal, 11)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    /// One selectable image row (`.img` in the design card): a leading checkbox — reusing the
    /// exact same `CacheCheckbox` control `SelectableItemRow`/`SelectableAppCacheRow` use — the
    /// image's repo:tag (or a short id fallback) in a monospaced font, and its size. Images
    /// still referenced by a container (`isUnused == false`) render greyed out with an
    /// "in use · skipped" note and a permanently-off, non-interactive checkbox: they are never
    /// selectable, matching `Reclaimer.cleanSelected`'s own `force: false` skip behavior.
    private func imageRow(_ image: ImageSummary) -> some View {
        HStack(spacing: 9) {
            CacheCheckbox(isOn: image.isUnused ? imageSelectionBinding(for: image.id) : .constant(false))
                .disabled(!image.isUnused)

            Text(image.repoTags.first ?? String(image.id.prefix(19)))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)

            Spacer()

            if image.isUnused {
                Text(appFormatBytes(image.size))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("in use \u{00B7} skipped")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 11)
        .padding(.vertical, 3)
        .opacity(image.isUnused ? 1 : 0.45)
    }

    private func imageSelectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { appState.selectedImageIDs.contains(id) },
            set: { _ in appState.toggleImageSelection(id) }
        )
    }

    /// "N selected · ≈ X" summary + the `CTAButtonStyle` action button. Disabled while a clean
    /// is already running or nothing is selected. Progress/result are **not** rendered here —
    /// `removeSelectedImages()` reuses `handle(event:)`, so they appear through the existing
    /// Docker `ProgressLogView(lines: appState.logLines)` + `resultSection` already wired up
    /// above in `body`.
    private func imageActionBar(df: DiskUsage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(appState.selectedImageIDs.count) selected \u{00B7} \u{2248} \(appFormatBytes(selectedImageBytes(df: df)))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button {
                appState.removeSelectedImages()
            } label: {
                HStack(spacing: 6) {
                    if appState.isCleaning {
                        ProgressView().controlSize(.small)
                    }
                    Text(appState.previewMode ? "See what I\u{2019}d remove" : "Remove selected images")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CTAButtonStyle())
            .disabled(appState.isCleaning || appState.selectedImageIDs.isEmpty)
        }
        .padding(.leading, 26)
        .padding(.trailing, 11)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func selectedImageBytes(df: DiskUsage) -> Int64 {
        df.images
            .filter { appState.selectedImageIDs.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 11)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    // MARK: - CTA block (`.ctawrap`)

    private func ctaSection(df: DiskUsage) -> some View {
        let readyBytes = df.buildCacheReclaimableSize + df.imagesReclaimableSize
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                Text("Ready to free ≈ \(appFormatBytes(readyBytes))")
                    .font(.system(size: 13.5, weight: .bold))
                Spacer()
                Text("data never touched")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button {
                appState.runClean()
            } label: {
                HStack(spacing: 6) {
                    if appState.isCleaning {
                        ProgressView().controlSize(.small)
                    }
                    Text(buttonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CTAButtonStyle())
            .disabled(appState.isCleaning)

            Toggle(isOn: $appState.previewMode) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show me first")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(toggleCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(appState.isCleaning)
        }
        .padding(.horizontal, 11)
        .padding(.top, 4)
        .padding(.bottom, 6)
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

    // MARK: - Result (`.res`)

    private func resultSection(report: CleanReport) -> some View {
        Group {
            if report.dryRun {
                let estimated = report.steps.reduce(Int64(0)) { $0 + $1.dockerReportedBytes }
                resultCard(
                    title: "You’d get back about \(appFormatBytes(estimated))",
                    caption: "Estimate — the real, measured number is shown after a cleanup.",
                    tint: Color.secondary.opacity(0.08)
                )
            } else {
                resultCard(
                    title: "🎉 \(appFormatBytes(report.hostDelta)) returned to your Mac",
                    caption: "The real number, measured on your disk — not Docker’s estimate.",
                    tint: Color.green.opacity(0.14)
                )
            }
        }
    }

    private func resultCard(title: String, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13.5, weight: .bold))
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(tint))
        .padding(.horizontal, 11)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    // MARK: - Start Colima

    private var startColimaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Docker isn’t running", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12.5, weight: .semibold))
            Text("Colima, OrbStack, Rancher Desktop, and Docker Desktop were all unreachable.")
                .font(.system(size: 11))
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
            .buttonStyle(CTAButtonStyle())
            .disabled(appState.isStartingColima)

            if !appState.logLines.isEmpty {
                ProgressLogView(lines: appState.logLines)
            }
        }
    }

    // MARK: - Footer (`.frow` + `.fine`)

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await appState.refresh() }
            } label: {
                HStack {
                    Text("Refresh").font(.system(size: 13))
                    if appState.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 11)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Text("Quit Reclaim").font(.system(size: 13))
                    Spacer()
                    Text("⌘Q")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .padding(.horizontal, 11)

            if !finePrint.isEmpty {
                Text(finePrint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
            }
        }
    }

    /// "Watching Colima · Cleaned 3 days ago, freed 12.4 GB" (docs/design/panel.html `.fine`),
    /// joined with the one-time slow-build note when applicable.
    private var finePrint: String {
        var parts: [String] = []
        if let backend = appState.detected {
            parts.append("Watching \(backend.backend.displayName)")
        }
        if let last = appState.history.first {
            parts.append("Cleaned \(relativeDateText(last.date)), freed \(appFormatBytes(last.hostDelta))")
        }
        if appState.showSlowBuildNote {
            parts.append("First build after a cleanup can be slower while Docker warms back up.")
        }
        return parts.joined(separator: " · ")
    }

    private func relativeDateText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// The CTA's own button style (matches `.cta`/`.cta:active` in panel.html): full-width, solid
/// fill, radius 8 — a tinted-background stock `ButtonStyle`, not a custom-chrome control.
struct CTAButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill(configuration)))
    }

    private func fill(_ configuration: Configuration) -> Color {
        guard isEnabled else { return Palette.ctaFill.opacity(0.5) }
        return configuration.isPressed ? Palette.ctaPressedFill : Palette.ctaFill
    }
}
