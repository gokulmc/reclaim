import Foundation

/// Options for `Reclaimer.clean`. **Dry-run is the default** (SPEC.md §2.4) — a caller has to
/// explicitly opt into `dryRun = false` to perform any mutating request.
public struct CleanOptions {
    public var dryRun: Bool
    public var pruneContainers: Bool
    public var forceTrim: Bool

    public init(dryRun: Bool = true, pruneContainers: Bool = false, forceTrim: Bool = false) {
        self.dryRun = dryRun
        self.pruneContainers = pruneContainers
        self.forceTrim = forceTrim
    }
}

/// Live progress emitted while `clean` runs, so both the CLI and (later) the menu bar UI can
/// render the same stream.
public enum CleanEvent {
    case step(String)
    case log(String)
    case done(CleanReport)
}

/// One prune step's result, as reported by Docker itself. This is *not* the headline number
/// (see `CleanReport.hostDelta`) — Docker's own accounting is misleading because images share
/// layers (SPEC.md §2.5) — but it's useful secondary detail.
public struct CleanStepResult: Equatable {
    public let name: String
    public let dockerReportedBytes: Int64

    public init(name: String, dockerReportedBytes: Int64) {
        self.name = name
        self.dockerReportedBytes = dockerReportedBytes
    }
}

public struct CleanReport: Equatable {
    public let dryRun: Bool
    /// `nil` for a dev-tool cache run (`CacheReclaimer`), which has no Docker backend — only
    /// `Reclaimer` (Docker) ever produces a report with a non-nil `backend`.
    public let backend: Backend?
    public let hostFreeBefore: Int64
    public let hostFreeAfter: Int64
    public let steps: [CleanStepResult]
    public let trimmedBytes: Int64
    public let trimNote: String?

    /// **The headline number** (SPEC.md §2.5): the real `statfs` delta, not Docker's
    /// estimate. In a dry run this is always `0` since nothing was actually removed.
    public var hostDelta: Int64 { hostFreeAfter - hostFreeBefore }

    public init(
        dryRun: Bool,
        backend: Backend?,
        hostFreeBefore: Int64,
        hostFreeAfter: Int64,
        steps: [CleanStepResult],
        trimmedBytes: Int64,
        trimNote: String?
    ) {
        self.dryRun = dryRun
        self.backend = backend
        self.hostFreeBefore = hostFreeBefore
        self.hostFreeAfter = hostFreeAfter
        self.steps = steps
        self.trimmedBytes = trimmedBytes
        self.trimNote = trimNote
    }
}

/// Orchestrates the full clean flow: probe host free space, prune images and build cache
/// (and optionally stopped containers), trim, probe again, and report the honest delta.
///
/// In a dry run, `clean` reads `systemDF()` (a `GET`, always safe) and reports what *would*
/// be removed using Docker's own numbers, clearly labeled as estimates — and issues **zero**
/// mutating requests (SPEC.md §2.4).
public struct Reclaimer {
    private let dockerClient: DockerClient
    private let backend: Backend
    private let trimService: TrimService
    private let diskProbePath: String

    public init(
        dockerClient: DockerClient,
        backend: Backend,
        trimService: TrimService = TrimService(),
        diskProbePath: String = "/"
    ) {
        self.dockerClient = dockerClient
        self.backend = backend
        self.trimService = trimService
        self.diskProbePath = diskProbePath
    }

    public func clean(
        options: CleanOptions = CleanOptions(),
        progress: @escaping (CleanEvent) -> Void = { _ in }
    ) async throws -> CleanReport {
        progress(.step("Checking host free space"))
        let before = try DiskProbe.stat(path: diskProbePath)

        progress(.step("Reading Docker disk usage"))
        let df = try await dockerClient.systemDF()

        if options.dryRun {
            return try dryRunReport(df: df, before: before, options: options, progress: progress)
        }

        return try await realRun(before: before, options: options, progress: progress)
    }

    private func dryRunReport(
        df: DiskUsage,
        before: DiskStat,
        options: CleanOptions,
        progress: @escaping (CleanEvent) -> Void
    ) throws -> CleanReport {
        progress(.log("DRY RUN — these are Docker's own estimates; no requests to prune anything are being sent."))
        progress(.log("Build cache: \(formatBytes(df.buildCacheReclaimableSize)) reclaimable (Docker estimate, \(df.buildCacheReclaimableCount) records)"))
        progress(.log("Images: \(formatBytes(df.imagesReclaimableSize)) reclaimable (Docker estimate, \(df.imagesReclaimableCount) unused)"))
        if options.pruneContainers {
            progress(.log("Containers: \(df.stoppedContainersCount) stopped, \(formatBytes(df.stoppedContainersSize)) (Docker estimate)"))
        }
        progress(.log("Trim step: skipped in a dry run — pass --run to actually clean."))

        var steps = [
            CleanStepResult(name: "build cache (Docker estimate)", dockerReportedBytes: df.buildCacheReclaimableSize),
            CleanStepResult(name: "images (Docker estimate)", dockerReportedBytes: df.imagesReclaimableSize)
        ]
        if options.pruneContainers {
            steps.append(CleanStepResult(name: "containers (Docker estimate)", dockerReportedBytes: df.stoppedContainersSize))
        }

        let report = CleanReport(
            dryRun: true,
            backend: backend,
            hostFreeBefore: before.freeBytes,
            hostFreeAfter: before.freeBytes,
            steps: steps,
            trimmedBytes: 0,
            trimNote: nil
        )
        progress(.done(report))
        return report
    }

    private func realRun(
        before: DiskStat,
        options: CleanOptions,
        progress: @escaping (CleanEvent) -> Void
    ) async throws -> CleanReport {
        var steps: [CleanStepResult] = []

        progress(.step("Pruning unused images"))
        let imagesResult = try await dockerClient.pruneImages()
        progress(.log("Images: Docker reports \(formatBytes(imagesResult.spaceReclaimed)) reclaimed"))
        steps.append(CleanStepResult(name: "images", dockerReportedBytes: imagesResult.spaceReclaimed))

        progress(.step("Pruning build cache"))
        let buildResult = try await dockerClient.pruneBuildCache()
        progress(.log("Build cache: Docker reports \(formatBytes(buildResult.spaceReclaimed)) reclaimed"))
        progress(.log("Note: the next build may be slower while the cache rebuilds (SPEC.md §7)."))
        steps.append(CleanStepResult(name: "build cache", dockerReportedBytes: buildResult.spaceReclaimed))

        if options.pruneContainers {
            progress(.step("Pruning stopped containers"))
            let containersResult = try await dockerClient.pruneContainers()
            progress(.log("Containers: Docker reports \(formatBytes(containersResult.spaceReclaimed)) reclaimed"))
            steps.append(CleanStepResult(name: "containers", dockerReportedBytes: containersResult.spaceReclaimed))
        }

        progress(.step("Trimming (this can take a while — fstrim prints nothing until it's done)"))
        var trimmedBytes: Int64 = 0
        var trimNote: String?
        do {
            let outcome = try await trimService.trim(
                backend: backend,
                forceTrim: options.forceTrim,
                progress: { line in progress(.log(line)) }
            )
            switch outcome {
            case .trimmed(let bytes):
                trimmedBytes = bytes
                progress(.log("Trim reclaimed \(formatBytes(bytes)) inside the VM disk image"))
            case .notNeeded(let reason):
                trimNote = reason
                progress(.log(reason))
            }
        } catch TrimError.backendStopped {
            trimNote = "Backend is stopped — trim skipped. Start it and run `trim` separately."
            progress(.log(trimNote!))
        }

        progress(.step("Re-checking host free space"))
        let after = try DiskProbe.stat(path: diskProbePath)

        let report = CleanReport(
            dryRun: false,
            backend: backend,
            hostFreeBefore: before.freeBytes,
            hostFreeAfter: after.freeBytes,
            steps: steps,
            trimmedBytes: trimmedBytes,
            trimNote: trimNote
        )
        progress(.done(report))
        return report
    }
}
