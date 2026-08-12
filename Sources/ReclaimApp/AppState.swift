import Foundation
import ReclaimKit
import ServiceManagement

/// All mutable app state lives here, on the main actor. Every engine call (disk probing,
/// backend detection, the Docker Engine API, the clean/trim run, `colima start`) is kicked
/// off from `Task.detached` so the actual syscalls/socket IO/process work happen off the main
/// thread; only the final `@Published` assignments happen back here (docs/IMPLEMENTATION.md,
/// App M1-M4: "All Docker/df calls off the main thread ... UI updates on @MainActor").
@MainActor
final class AppState: ObservableObject {
    // MARK: - Disk / backend / usage snapshot

    @Published private(set) var diskStat: DiskStat?
    @Published private(set) var detected: DetectedBackend?
    @Published private(set) var diskUsage: DiskUsage?
    @Published private(set) var isRefreshing = false

    // MARK: - Dev-tool caches (M1: read-only visibility, see docs/design/caches-section.html)

    /// Backend-independent — populated in `refresh()` regardless of whether a Docker backend
    /// was detected, so the "Dev tool caches" section still renders when Docker is down.
    @Published private(set) var caches: [ScannedCache] = []

    /// Sum of every scanned cache (single-directory tools + all per-app `~/Library/Caches`
    /// children) — the number `CacheSectionView` shows next to "Dev tool caches" at rest.
    var cachesTotalBytes: Int64 {
        caches.reduce(0) { $0 + $1.sizeBytes }
    }

    /// IDs ticked in the "Dev tool caches" section (M3b) — `ScannedCache.id`s: either a
    /// single-directory definition id (e.g. `"npm"`) or a per-app child id (e.g.
    /// `"library-caches/com.apple.Safari"`). Nothing is pre-ticked (plan: "nothing pre-ticked
    /// by default, with a Select all safe button").
    @Published var selectedCacheIDs: Set<String> = []

    /// Self-contained progress log for the cache clean flow. Deliberately **not** the Docker
    /// `logLines` below — `CacheSectionView` renders its own progress/result entirely inside
    /// itself, so the Docker CTA's log/result area is never touched by (or touches) a cache run.
    @Published private(set) var cacheLogLines: [String] = []
    @Published private(set) var cacheReport: CleanReport?
    @Published private(set) var isCleaningCaches = false

    // MARK: - Large files & folders (M-LF7/M-LF8, see docs/design/large-files-section.html)

    /// The most recent whole-home scan's ranked results (both large files and large folders,
    /// largest first — `LargeItemScanner` already sorts). Empty until the user explicitly
    /// triggers `startLargeFileScan()`; **never** populated by `refresh()`'s 60s poll — a
    /// whole-home walk is comparatively expensive, and this is the app's first feature that can
    /// delete arbitrary user files, so it stays strictly button-triggered.
    @Published private(set) var largeItems: [LargeItem] = []
    /// IDs ticked in the danger-zone list — only ever `LargeItem.id`s where `isSelectable` is
    /// true (`toggleLargeItemSelection` guards this). Nothing pre-ticked, and there is no
    /// "select all" for this section.
    @Published var selectedLargeItemIDs: Set<String> = []
    @Published private(set) var isScanningLargeFiles = false
    @Published private(set) var largeScanProgress: LargeScanProgress?
    @Published private(set) var largeFilesSkippedAreas: [String] = []
    @Published private(set) var largeFilesNeedsFullDiskAccess = false

    /// Self-contained, exactly like `cacheLogLines`/`cacheReport`/`isCleaningCaches` above — the
    /// large-files move-to-Trash flow never reads or writes Docker's `logLines`/`lastReport` or
    /// the dev-tool cache flow's `cacheLogLines`/`cacheReport`.
    @Published private(set) var largeFilesLog: [String] = []
    @Published private(set) var largeFilesReport: CleanReport?
    @Published private(set) var isTrashingLargeFiles = false
    /// Arms the confirmation `.alert` in `LargeFilesSectionView`; only `requestTrashSelected()`
    /// sets it true, and the alert itself (Move to Trash or Cancel) is what sets it back false.
    @Published var showLargeFilesTrashConfirmation = false
    /// A **dedicated** preview flag for the danger zone — deliberately independent of the
    /// shared Docker/caches `previewMode` below, so toggling one never silently arms the other.
    /// Defaults to `true` (dry-run first), mirroring `previewMode`'s own default and SPEC.md
    /// §2.4's "dry-run must be the default" rule.
    @Published var largeFilesPreviewMode: Bool = true

    // MARK: - Clean run

    /// Dry-run is ON by default (SPEC.md §2.4: dry-run must be the default).
    @Published var previewMode: Bool = true
    @Published private(set) var isCleaning = false
    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastReport: CleanReport?
    /// One-time note shown after a real (non-preview) run that pruned build cache (SPEC.md
    /// §7: the next build may be slower while the cache rebuilds). Reset at the start of every
    /// run so it never lingers past the run that produced it.
    @Published private(set) var showSlowBuildNote = false

    // MARK: - Docker per-image selection (M4b, docs/design/docker-image-selection.html)

    /// IDs ticked in the opt-in "Remove specific images…" disclosure under the Docker "Unused
    /// app images" row. Nothing pre-ticked — same "nothing selected by default" convention as
    /// `selectedCacheIDs`. This is a **Docker** operation (unlike the cache flow), so it
    /// deliberately shares `logLines`/`lastReport`/`isCleaning`/`recordHistory` with `runClean()`
    /// rather than getting its own parallel state.
    @Published var selectedImageIDs: Set<String> = []

    // MARK: - History

    @Published private(set) var history: [HistoryEntry] = []

    // MARK: - Start Colima

    @Published private(set) var isStartingColima = false

    // MARK: - Scheduling (M4)

    @Published private(set) var schedulingStatus: SMAppService.Status = .notRegistered
    @Published private(set) var schedulingError: String?

    private let historyStore = HistoryStore()
    private let schedulingService = SMAppService.agent(plistName: "com.gokul.reclaim.agent.plist")
    private var pollTask: Task<Void, Never>?
    /// Retained so `cancelLargeFileScan()` can actually cancel an in-flight whole-home walk —
    /// mirrors `pollTask` above.
    private var largeScanTask: Task<Void, Never>?

    /// How many `Reclaimer` "step" events have been mapped to a numbered plain-language header
    /// so far in the current run (see `handle(event:)` below).
    private var completedMappedSteps = 0
    /// Build cache + images + trim = 3. `pruneContainers` is hardcoded to `false` in
    /// `runClean()` below, so a "Pruning stopped containers" step never fires today; if that
    /// ever becomes a user-facing option, this needs to become dynamic (options.pruneContainers
    /// ? 4 : 3) rather than a constant.
    private let totalMappedSteps = 3

    // MARK: - Derived

    var diskLevel: DiskLevel {
        guard let diskStat else { return .green }
        return DiskLevel(freeBytes: diskStat.freeBytes, totalBytes: diskStat.totalBytes)
    }

    /// Menu bar label text — whole numbers only ("54 GB"), per the approved icon card.
    var freeSpaceText: String {
        guard let diskStat else { return "…" }
        return appFormatBytesWhole(diskStat.freeBytes)
    }

    init() {
        refreshSchedulingStatus()
        loadHistory()
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Polling (DiskProbe every 60s per SPEC/IMPLEMENTATION)

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Re-probes host free space, re-detects the live backend, and (if one is live) re-reads
    /// the Docker usage breakdown. Nothing here mutates anything — this is always safe to call
    /// on a timer or after a run.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        if let stat = await Task.detached(priority: .utility, operation: { try? DiskProbe.stat() }).value {
            diskStat = stat
        }

        // Dev-tool caches live on disk regardless of whether a Docker backend is running, so
        // this is scanned unconditionally — unlike `diskUsage` below, it never depends on
        // `detected`.
        caches = await Task.detached(priority: .utility) { () -> [ScannedCache] in
            CacheScanner().scan(CacheCatalog.default())
        }.value

        let detectedBackends = await Task.detached(priority: .utility) { BackendDetector.detect() }.value
        detected = detectedBackends.first

        guard let detected else {
            diskUsage = nil
            return
        }

        let socketPath = detected.socketPath
        diskUsage = await Task.detached(priority: .utility) { () -> DiskUsage? in
            let client = DockerClient(socketPath: socketPath)
            return try? await client.systemDF()
        }.value
    }

    // MARK: - Clean

    /// Kicks off `Reclaimer.clean` on a detached task and streams its `CleanEvent`s back to
    /// the main actor through an `AsyncStream`, so log lines appear live while the run is in
    /// progress rather than only once it finishes. The Reclaim button is the only way this
    /// gets called — nothing here runs automatically (SPEC.md §2.4).
    func runClean() {
        guard !isCleaning, let detected else { return }
        isCleaning = true
        logLines.removeAll()
        lastReport = nil
        showSlowBuildNote = false
        completedMappedSteps = 0

        let backend = detected.backend
        let socketPath = detected.socketPath
        let options = CleanOptions(dryRun: previewMode, pruneContainers: false, forceTrim: false)

        let (stream, continuation) = AsyncStream<CleanEvent>.makeStream()

        Task.detached(priority: .userInitiated) {
            let client = DockerClient(socketPath: socketPath)
            let reclaimer = Reclaimer(dockerClient: client, backend: backend)
            do {
                _ = try await reclaimer.clean(options: options) { event in
                    continuation.yield(event)
                }
            } catch {
                continuation.yield(.log("Error: \(error)"))
            }
            continuation.finish()
        }

        Task {
            for await event in stream {
                handle(event: event)
            }
            // Fallback in case the stream ended without a `.done` (e.g. a thrown error) —
            // never leave the button stuck in "Reclaiming...".
            isCleaning = false
        }
    }

    /// Maps a raw `CleanEvent.step` name (`ReclaimKit`/CLI technical language) to the plain
    /// header the redesigned progress log shows instead (docs/design/copy.html: "Log stages
    /// get plain headers; raw tool output stays underneath"). The three headed steps get a
    /// "Step N of `totalMappedSteps`" prefix; the bookkeeping steps around them (checking free
    /// space before/after, reading Docker's usage) get a plain caption with no step number,
    /// since they're not part of the "3 steps" the design shows the user.
    ///
    /// This intentionally lives here in the app layer, not in `ReclaimKit` — the CLI keeps
    /// seeing the exact same technical step names `Reclaimer` always emitted.
    private func plainLogLine(for event: CleanEvent) -> String {
        switch event {
        case .step("Pruning build cache"):
            completedMappedSteps += 1
            return "Step \(completedMappedSteps) of \(totalMappedSteps) — clearing build leftovers…"
        case .step("Pruning unused images"):
            completedMappedSteps += 1
            return "Step \(completedMappedSteps) of \(totalMappedSteps) — removing unused app images…"
        case .step("Pruning stopped containers"):
            completedMappedSteps += 1
            return "Step \(completedMappedSteps) of \(totalMappedSteps) — clearing finished containers…"
        case .step(let text) where text.hasPrefix("Trimming"):
            completedMappedSteps += 1
            return "Step \(completedMappedSteps) of \(totalMappedSteps) — handing the space back to macOS… "
                + "this one takes a minute — Docker's disk is being shrunk"
        case .step("Checking host free space"):
            return "Checking your Mac's free space…"
        case .step("Reading Docker disk usage"):
            return "Looking at what Docker's using…"
        case .step("Re-checking host free space"):
            return "Confirming the new free space…"
        case .step(let text):
            return text
        case .log(let text):
            return "    \(text)"
        case .done:
            return ""
        }
    }

    private func handle(event: CleanEvent) {
        switch event {
        case .step, .log:
            logLines.append(plainLogLine(for: event))
        case .done(let report):
            lastReport = report
            isCleaning = false
            guard !report.dryRun else { return }
            if report.steps.contains(where: { $0.name == "build cache" }) {
                showSlowBuildNote = true
            }
            recordHistory(for: report)
            Task { await self.refresh() }
        }
    }

    private func recordHistory(for report: CleanReport) {
        let entry = HistoryEntry(
            date: Date(),
            backend: report.backend,
            imagesReclaimed: report.steps.first(where: { $0.name == "images" })?.dockerReportedBytes ?? 0,
            buildCacheReclaimed: report.steps.first(where: { $0.name == "build cache" })?.dockerReportedBytes ?? 0,
            containersReclaimed: report.steps.first(where: { $0.name == "containers" })?.dockerReportedBytes ?? 0,
            trimmedBytes: report.trimmedBytes,
            hostDelta: report.hostDelta
        )
        do {
            try historyStore.append(entry)
            loadHistory()
        } catch {
            logLines.append("warning: failed to record history: \(error)")
        }
    }

    func loadHistory() {
        history = ((try? historyStore.load()) ?? []).sorted { $0.date > $1.date }
    }

    // MARK: - Docker per-image selection + removal (M4b, docs/design/docker-image-selection.html)

    func toggleImageSelection(_ id: String) {
        if selectedImageIDs.contains(id) {
            selectedImageIDs.remove(id)
        } else {
            selectedImageIDs.insert(id)
        }
    }

    func clearImageSelection() {
        selectedImageIDs.removeAll()
    }

    /// Kicks off `Reclaimer.cleanSelected` on a detached task and streams its `CleanEvent`s back
    /// to the main actor, mirroring `runClean()`'s detached-work/`AsyncStream`/@MainActor-
    /// assignment shape exactly — same `DockerClient`/`Reclaimer` construction off-thread, same
    /// `handle(event:)` consumer. Unlike the dev-tool cache flow (which is deliberately kept
    /// separate from the Docker CTA's state), this **is** a Docker operation, so reusing the
    /// existing `logLines`/`lastReport`/`isCleaning`/`recordHistory` is correct and intended —
    /// the per-image progress/result surfaces through the same `ProgressLogView`/result card
    /// `DetailPanelView` already renders for `runClean()`. `runClean()` itself is untouched.
    func removeSelectedImages() {
        guard !isCleaning, !selectedImageIDs.isEmpty, let detected else { return }
        isCleaning = true
        logLines.removeAll()
        lastReport = nil
        showSlowBuildNote = false
        completedMappedSteps = 0

        let backend = detected.backend
        let socketPath = detected.socketPath
        let selection = DockerSelection(imageIDs: Array(selectedImageIDs), includeBuildCache: false)
        let options = CleanOptions(dryRun: previewMode)

        let (stream, continuation) = AsyncStream<CleanEvent>.makeStream()

        Task.detached(priority: .userInitiated) {
            let client = DockerClient(socketPath: socketPath)
            let reclaimer = Reclaimer(dockerClient: client, backend: backend)
            do {
                _ = try await reclaimer.cleanSelected(selection, options: options) { event in
                    continuation.yield(event)
                }
            } catch {
                continuation.yield(.log("Error: \(error)"))
            }
            continuation.finish()
        }

        Task {
            for await event in stream {
                handle(event: event)
            }
            // Fallback in case the stream ended without a `.done` (e.g. a thrown error) — never
            // leave the button stuck, and always clear the selection once this run is over
            // (successful or not) so a stale image id never lingers into the next refresh.
            isCleaning = false
            selectedImageIDs.removeAll()
        }
    }

    // MARK: - Dev-tool cache selection + clean (M3b, see docs/design/caches-section.html)

    func toggleCacheSelection(_ id: String) {
        if selectedCacheIDs.contains(id) {
            selectedCacheIDs.remove(id)
        } else {
            selectedCacheIDs.insert(id)
        }
    }

    /// Ticks every scanned cache whose `CacheDefinition` regenerates on its own AND expands as
    /// a single directory — i.e. every "safe" tool cache (npm, Xcode DerivedData, Homebrew, ...)
    /// but never the per-app `~/Library/Caches` children, which aren't a blanket "safe" set
    /// (some apps rely on their cache surviving between launches more than others).
    func selectAllSafeCaches() {
        let safeDefinitionIDs = Set(
            CacheCatalog.default()
                .filter { $0.regenerates && $0.expansion == .singleDirectory }
                .map(\.id)
        )
        selectedCacheIDs = Set(
            caches.filter { safeDefinitionIDs.contains($0.definitionID) }.map(\.id)
        )
    }

    func clearCacheSelection() {
        selectedCacheIDs.removeAll()
    }

    /// Kicks off `CacheReclaimer.clean` on a detached task and streams its `CleanEvent`s back to
    /// the main actor, mirroring `runClean()`'s detached-work/`AsyncStream`/@MainActor-assignment
    /// shape exactly — but writing into the cache-only `cacheLogLines`/`cacheReport`/
    /// `isCleaningCaches` state above, never the Docker `logLines`/`lastReport`/`isCleaning`.
    /// `.step`/`.log` text is appended verbatim (no "Step N of 3" mapping — that mapper is
    /// Docker-step-name-specific and lives in `plainLogLine(for:)` above).
    func cleanSelectedCaches() {
        guard !isCleaningCaches, !selectedCacheIDs.isEmpty else { return }
        isCleaningCaches = true
        cacheLogLines.removeAll()
        cacheReport = nil

        let selection = selectedCacheIDs
        let options = CleanOptions(dryRun: previewMode)

        let (stream, continuation) = AsyncStream<CleanEvent>.makeStream()

        Task.detached(priority: .userInitiated) {
            let reclaimer = CacheReclaimer()
            do {
                _ = try await reclaimer.clean(selection: selection, options: options) { event in
                    continuation.yield(event)
                }
            } catch {
                continuation.yield(.log("Error: \(error)"))
            }
            continuation.finish()
        }

        Task {
            for await event in stream {
                handle(cacheEvent: event)
            }
            // Fallback in case the stream ended without a `.done` (e.g. a thrown error) — never
            // leave the button stuck in "Cleaning...".
            isCleaningCaches = false
        }
    }

    private func handle(cacheEvent event: CleanEvent) {
        switch event {
        case .step(let text):
            cacheLogLines.append(text)
        case .log(let text):
            cacheLogLines.append(text)
        case .done(let report):
            cacheReport = report
            isCleaningCaches = false
            guard !report.dryRun else { return }
            recordCacheHistory(for: report)
            Task { await self.refresh() }
        }
    }

    private func recordCacheHistory(for report: CleanReport) {
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
            try historyStore.append(entry)
            loadHistory()
        } catch {
            cacheLogLines.append("warning: failed to record history: \(error)")
        }
    }

    // MARK: - Large files & folders (M-LF7/M-LF8, see docs/design/large-files-section.html)

    /// Emitted by the scan's `AsyncStream` consumer below — wraps `LargeScanProgress`/
    /// `LargeScanResult` (both `ReclaimKit`) so a single stream can carry live progress ticks
    /// alongside the final result.
    private enum LargeScanEvent {
        case progress(LargeScanProgress)
        case finished(LargeScanResult)
    }

    /// Kicks off a whole-home scan: probes Full Disk Access off-thread, then drives
    /// `LargeItemScanner.scan` on a **retained** detached task through an `AsyncStream`,
    /// mirroring `cleanSelectedCaches()`'s detached-work/stream/consumer shape. Button-triggered
    /// only — never called from `refresh()` or the 60s poll.
    func startLargeFileScan() {
        guard !isScanningLargeFiles else { return }
        isScanningLargeFiles = true
        largeFilesLog.removeAll()
        largeFilesReport = nil
        largeScanProgress = nil
        largeItems = []
        selectedLargeItemIDs.removeAll()

        Task {
            let probe = await Task.detached(priority: .utility) {
                FullDiskAccessProbe().probe()
            }.value
            largeFilesNeedsFullDiskAccess = probe.needsFullDiskAccess
        }

        let (stream, continuation) = AsyncStream<LargeScanEvent>.makeStream()

        largeScanTask = Task.detached(priority: .utility) {
            let scanner = LargeItemScanner()
            let result = await scanner.scan { progress in
                continuation.yield(.progress(progress))
            }
            continuation.yield(.finished(result))
            continuation.finish()
        }

        Task {
            for await event in stream {
                handle(largeScanEvent: event)
            }
        }
    }

    /// `LargeItemScanner.scan` checks `Task.isCancelled` throughout its recursive walk and
    /// returns a partial `LargeScanResult` with `wasCancelled == true` rather than throwing, so
    /// cancelling `largeScanTask` here still lets the stream consumer above finish cleanly and
    /// `isScanningLargeFiles` still gets cleared via the normal `.finished` handling.
    func cancelLargeFileScan() {
        largeScanTask?.cancel()
    }

    private func handle(largeScanEvent event: LargeScanEvent) {
        switch event {
        case .progress(let progress):
            largeScanProgress = progress
        case .finished(let result):
            largeItems = result.items
            largeFilesSkippedAreas = result.skippedAreas
            isScanningLargeFiles = false
            largeScanProgress = nil
        }
    }

    /// Only a non-protected item can ever be selected — `LargeItem.isSelectable` mirrors
    /// `FileTrashGuard.validate`'s rejection, so a protected id is silently ignored here rather
    /// than trusted to have never been passed in. No "select all" for this section.
    func toggleLargeItemSelection(_ id: String) {
        guard let item = largeItems.first(where: { $0.id == id }), item.isSelectable else { return }
        if selectedLargeItemIDs.contains(id) {
            selectedLargeItemIDs.remove(id)
        } else {
            selectedLargeItemIDs.insert(id)
        }
    }

    func clearLargeSelection() {
        selectedLargeItemIDs.removeAll()
    }

    /// Arms the confirmation alert — the actual move only ever happens from
    /// `moveSelectedToTrash(dryRun:)`, called by the alert's own destructive button.
    func requestTrashSelected() {
        showLargeFilesTrashConfirmation = true
    }

    /// Kicks off `LargeFilesReclaimer.trash` on a detached task and streams its `CleanEvent`s
    /// back to the main actor, mirroring `cleanSelectedCaches()`'s shape exactly — but writing
    /// only into the large-files-only `largeFilesLog`/`largeFilesReport`/`isTrashingLargeFiles`
    /// state, never Docker's or the dev-tool cache flow's.
    func moveSelectedToTrash(dryRun: Bool) {
        guard !isTrashingLargeFiles, !selectedLargeItemIDs.isEmpty else { return }
        isTrashingLargeFiles = true
        largeFilesLog.removeAll()
        largeFilesReport = nil

        let selection = largeItems.filter { selectedLargeItemIDs.contains($0.id) && $0.isSelectable }
        let options = CleanOptions(dryRun: dryRun)

        let (stream, continuation) = AsyncStream<CleanEvent>.makeStream()

        Task.detached(priority: .userInitiated) {
            let reclaimer = LargeFilesReclaimer()
            do {
                _ = try await reclaimer.trash(selection: selection, options: options) { event in
                    continuation.yield(event)
                }
            } catch {
                continuation.yield(.log("Error: \(error)"))
            }
            continuation.finish()
        }

        Task {
            for await event in stream {
                handle(largeFilesEvent: event)
            }
            // Fallback in case the stream ended without a `.done` (e.g. a thrown error) — never
            // leave the button stuck.
            isTrashingLargeFiles = false
        }
    }

    private func handle(largeFilesEvent event: CleanEvent) {
        switch event {
        case .step(let text):
            largeFilesLog.append(text)
        case .log(let text):
            largeFilesLog.append(text)
        case .done(let report):
            largeFilesReport = report
            isTrashingLargeFiles = false
            guard !report.dryRun else { return }
            recordLargeFilesHistory(for: report)
            selectedLargeItemIDs.removeAll()
            Task { await self.refresh() }
        }
    }

    private func recordLargeFilesHistory(for report: CleanReport) {
        let entry = HistoryEntry(
            date: Date(),
            backend: nil,
            imagesReclaimed: 0,
            buildCacheReclaimed: 0,
            containersReclaimed: 0,
            trimmedBytes: 0,
            hostDelta: report.hostDelta,
            source: .largeFiles,
            cachesReclaimed: report.hostDelta
        )
        do {
            try historyStore.append(entry)
            loadHistory()
        } catch {
            largeFilesLog.append("warning: failed to record history: \(error)")
        }
    }

    // MARK: - Start Colima

    /// Runs `colima start`, streaming its output into the same log the clean flow uses, then
    /// re-detects the backend once it finishes.
    func startColima() {
        guard !isStartingColima else { return }
        isStartingColima = true
        logLines.removeAll()
        logLines.append("Starting Docker (Colima)…")

        let (stream, continuation) = AsyncStream<String>.makeStream()

        Task.detached(priority: .userInitiated) {
            await ProcessRunner.run(command: "colima", arguments: ["start"]) { line in
                continuation.yield(line)
            }
            continuation.finish()
        }

        Task {
            for await line in stream {
                logLines.append(line)
            }
            isStartingColima = false
            await refresh()
        }
    }

    // MARK: - Scheduling (M4)

    func refreshSchedulingStatus() {
        schedulingStatus = schedulingService.status
    }

    /// Registers/unregisters the weekly LaunchAgent. Off by default — this is only ever called
    /// from the "Clean weekly" toggle, never automatically.
    func setSchedulingEnabled(_ enabled: Bool) {
        schedulingError = nil
        do {
            if enabled {
                try schedulingService.register()
            } else {
                try schedulingService.unregister()
            }
        } catch {
            schedulingError = error.localizedDescription
        }
        refreshSchedulingStatus()
    }
}
