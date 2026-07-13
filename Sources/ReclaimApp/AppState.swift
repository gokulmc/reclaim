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

    // MARK: - Derived

    var diskLevel: DiskLevel {
        guard let diskStat else { return .green }
        return DiskLevel(freeBytes: diskStat.freeBytes, totalBytes: diskStat.totalBytes)
    }

    var freeSpaceText: String {
        guard let diskStat else { return "…" }
        return formatBytes(diskStat.freeBytes)
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

    private func handle(event: CleanEvent) {
        switch event {
        case .step(let text):
            logLines.append("==> \(text)")
        case .log(let text):
            logLines.append("    \(text)")
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
        logLines.append("==> Starting Colima")

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
