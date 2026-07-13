import ArgumentParser
import Foundation
import ReclaimKit

struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Prune unused images/build cache and trim the VM disk image so macOS actually gets space back.",
        discussion: """
        Dry-run by default: prints what would be removed using Docker's own estimates and
        sends zero mutating requests. Pass --run to actually perform the clean.

        Pass --image (repeatable) to remove one or more specific images by ID instead of
        sweeping every unused image — the named selective cleanup path. An image Docker
        refuses to remove (still in use, or referenced by more than one tag) is skipped with
        a log line rather than aborting the rest of the selection. Combine with --build-cache
        to also prune the build cache in the same run, or pass --build-cache alone to prune
        just the build cache without touching any image.
        """
    )

    @Flag(name: .customLong("run"), help: "Actually perform the clean. Without this flag, clean only previews what would happen.")
    var runClean: Bool = false

    @Flag(name: .customLong("containers"), help: "Also prune stopped containers.")
    var pruneContainers: Bool = false

    @Flag(name: .customLong("force-trim"), help: "Docker Desktop only: force the privileged nsenter fstrim fallback.")
    var forceTrim: Bool = false

    @Flag(name: .customLong("notify"), help: "Post a macOS notification with the result (intended for scheduled runs).")
    var notify: Bool = false

    @Option(name: .customLong("image"), help: "Remove a specific Docker image by ID instead of sweeping all unused images (repeatable).")
    var images: [String] = []

    @Flag(name: .customLong("build-cache"), help: "Prune the Docker build cache. Combine with --image, or pass alone to prune only the build cache.")
    var buildCacheOnly: Bool = false

    func run() async throws {
        let detected = try detectBackendOrThrow()
        let client = DockerClient(socketPath: detected.socketPath)
        let reclaimer = Reclaimer(dockerClient: client, backend: detected.backend)

        let options = CleanOptions(dryRun: !runClean, pruneContainers: pruneContainers, forceTrim: forceTrim)
        let isSelectiveRun = !images.isEmpty || buildCacheOnly

        print("Backend: \(detected.backend.displayName)")
        if options.dryRun {
            print("DRY RUN — no changes will be made. Pass --run to actually clean.\n")
        } else {
            print("")
        }

        func printProgress(_ event: CleanEvent) {
            switch event {
            case .step(let text):
                print("==> \(text)")
            case .log(let text):
                print("    \(text)")
            case .done:
                break
            }
        }

        let report: CleanReport
        if isSelectiveRun {
            let selection = DockerSelection(imageIDs: images, includeBuildCache: buildCacheOnly)
            report = try await reclaimer.cleanSelected(selection, options: options, progress: printProgress)
        } else {
            report = try await reclaimer.clean(options: options, progress: printProgress)
        }

        print("")
        if report.dryRun {
            let estimatedTotal = report.steps.reduce(Int64(0)) { $0 + $1.dockerReportedBytes }
            print("Would reclaim roughly \(formatBytes(estimatedTotal)) (Docker's estimate — the actual amount returned to macOS can differ; run with --run to see the real number).")
        } else {
            print("Returned \(formatBytes(report.hostDelta)) to macOS (host free: \(formatBytes(report.hostFreeBefore)) \u{2192} \(formatBytes(report.hostFreeAfter)))")

            // A selective run's per-image steps are named "image <id>" rather than the single
            // "images" step `clean()` produces — sum either shape so history still records a
            // meaningful imagesReclaimed total.
            let imagesReclaimed = report.steps
                .filter { $0.name == "images" || $0.name.hasPrefix("image ") }
                .reduce(Int64(0)) { $0 + $1.dockerReportedBytes }

            let entry = HistoryEntry(
                date: Date(),
                backend: report.backend,
                imagesReclaimed: imagesReclaimed,
                buildCacheReclaimed: report.steps.first(where: { $0.name == "build cache" })?.dockerReportedBytes ?? 0,
                containersReclaimed: report.steps.first(where: { $0.name == "containers" })?.dockerReportedBytes ?? 0,
                trimmedBytes: report.trimmedBytes,
                hostDelta: report.hostDelta,
                source: .docker
            )
            do {
                try HistoryStore().append(entry)
            } catch {
                FileHandle.standardError.write(Data("warning: failed to record history: \(error)\n".utf8))
            }

            if notify {
                notifyUser(message: "Reclaimed \(formatBytes(report.hostDelta))")
            }
        }
    }
}
