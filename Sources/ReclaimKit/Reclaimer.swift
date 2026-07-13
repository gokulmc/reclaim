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

/// A named selection of Docker items for `Reclaimer.cleanSelected` — the "pick exactly these"
/// counterpart to `clean`'s all-unused sweep.
public struct DockerSelection: Equatable {
    /// Image IDs (or `repo:tag`, so long as it contains no `/`) to remove individually via
    /// `DockerClient.deleteImage`.
    public var imageIDs: [String]
    /// Also prune the build cache (`DockerClient.pruneBuildCache()`) as part of this run.
    /// Build cache has no stable delete-by-id in the Docker API, so it stays all-or-nothing.
    public var includeBuildCache: Bool

    public init(imageIDs: [String] = [], includeBuildCache: Bool = false) {
        self.imageIDs = imageIDs
        self.includeBuildCache = includeBuildCache
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

    // MARK: - Named selective Docker cleanup

    /// The "pick exactly these" sibling of `clean`: removes only the images (and, optionally,
    /// the build cache) named in `selection`, rather than sweeping everything unused. Mirrors
    /// `clean`'s probe → read → (dry-run report | real run → trim → probe) shape and emits the
    /// same `CleanEvent` stream, so callers (CLI, and later the app) reuse their existing
    /// progress-printing/history code unchanged.
    ///
    /// `clean`/`realRun`/`dryRunReport` above are untouched by this addition — their pinned
    /// dry-run-is-zero-mutation test still exercises the exact same code path it always has.
    public func cleanSelected(
        _ selection: DockerSelection,
        options: CleanOptions = CleanOptions(),
        progress: @escaping (CleanEvent) -> Void = { _ in }
    ) async throws -> CleanReport {
        progress(.step("Checking host free space"))
        let before = try DiskProbe.stat(path: diskProbePath)

        progress(.step("Reading Docker disk usage"))
        let df = try await dockerClient.systemDF()

        if options.dryRun {
            return dryRunSelectedReport(selection: selection, df: df, before: before, progress: progress)
        }

        return try await realRunSelected(selection: selection, df: df, before: before, options: options, progress: progress)
    }

    private func dryRunSelectedReport(
        selection: DockerSelection,
        df: DiskUsage,
        before: DiskStat,
        progress: @escaping (CleanEvent) -> Void
    ) -> CleanReport {
        progress(.log("DRY RUN — these are Docker's own estimates; no requests to remove anything are being sent."))

        var steps: [CleanStepResult] = []
        for imageID in selection.imageIDs {
            let estimatedSize = df.images.first(where: { $0.id == imageID })?.size ?? 0
            progress(.log("would remove \(imageID) (~\(formatBytes(estimatedSize)))"))
            steps.append(CleanStepResult(name: "image \(imageID) (Docker estimate)", dockerReportedBytes: estimatedSize))
        }

        if selection.includeBuildCache {
            progress(.log("Build cache: \(formatBytes(df.buildCacheReclaimableSize)) reclaimable (Docker estimate, \(df.buildCacheReclaimableCount) records)"))
            steps.append(CleanStepResult(name: "build cache (Docker estimate)", dockerReportedBytes: df.buildCacheReclaimableSize))
        }

        progress(.log("Trim step: skipped in a dry run — pass --run to actually clean."))

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

    private func realRunSelected(
        selection: DockerSelection,
        df: DiskUsage,
        before: DiskStat,
        options: CleanOptions,
        progress: @escaping (CleanEvent) -> Void
    ) async throws -> CleanReport {
        var steps: [CleanStepResult] = []

        for imageID in selection.imageIDs {
            progress(.step("Removing image \(Self.shortImageID(imageID))"))
            let estimatedSize = df.images.first(where: { $0.id == imageID })?.size ?? 0
            do {
                let result = try await dockerClient.deleteImage(id: imageID, force: false)
                let label = result.deleted.first ?? imageID
                progress(.log("Removed \(label) (~\(formatBytes(estimatedSize)))"))
                steps.append(CleanStepResult(name: "image \(imageID)", dockerReportedBytes: estimatedSize))
            } catch {
                // Docker refused (409: still referenced by a running container, or by more
                // than one tag, since `force` is always false here) — skip and keep going
                // rather than aborting the whole selection over one image.
                progress(.log("Skipped \(imageID): \(error) (in use or multi-tagged)"))
            }
        }

        if selection.includeBuildCache {
            progress(.step("Pruning build cache"))
            let buildResult = try await dockerClient.pruneBuildCache()
            progress(.log("Build cache: Docker reports \(formatBytes(buildResult.spaceReclaimed)) reclaimed"))
            progress(.log("Note: the next build may be slower while the cache rebuilds (SPEC.md §7)."))
            steps.append(CleanStepResult(name: "build cache", dockerReportedBytes: buildResult.spaceReclaimed))
        }

        progress(.step("Trimming (this can take a while — fstrim prints nothing until it's done)"))
        let (trimmedBytes, trimNote) = try await runTrimStep(options: options, progress: progress)

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

    /// Same `TrimService` call + `backendStopped` handling as the trim step inside `realRun`
    /// (kept as a private helper here, rather than factored out of `realRun` itself, so
    /// `realRun`'s existing body — and the tests pinned to it — stays untouched).
    private func runTrimStep(
        options: CleanOptions,
        progress: @escaping (CleanEvent) -> Void
    ) async throws -> (trimmedBytes: Int64, trimNote: String?) {
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
        return (trimmedBytes, trimNote)
    }

    private static func shortImageID(_ id: String) -> String {
        let withoutPrefix = id.hasPrefix("sha256:") ? String(id.dropFirst("sha256:".count)) : id
        return String(withoutPrefix.prefix(12))
    }
}
