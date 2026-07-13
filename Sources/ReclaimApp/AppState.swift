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
