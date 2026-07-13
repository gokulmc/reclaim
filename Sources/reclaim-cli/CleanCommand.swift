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

    func run() async throws {
        let detected = try detectBackendOrThrow()
        let client = DockerClient(socketPath: detected.socketPath)
        let reclaimer = Reclaimer(dockerClient: client, backend: detected.backend)

        let options = CleanOptions(dryRun: !runClean, pruneContainers: pruneContainers, forceTrim: forceTrim)

        print("Backend: \(detected.backend.displayName)")
        if options.dryRun {
            print("DRY RUN — no changes will be made. Pass --run to actually clean.\n")
        } else {
            print("")
        }

        let report = try await reclaimer.clean(options: options) { event in
            switch event {
            case .step(let text):
                print("==> \(text)")
            case .log(let text):
                print("    \(text)")
            case .done:
                break
            }
        }

        print("")
        if report.dryRun {
            let estimatedTotal = report.steps.reduce(Int64(0)) { $0 + $1.dockerReportedBytes }
            print("Would reclaim roughly \(formatBytes(estimatedTotal)) (Docker's estimate — the actual amount returned to macOS can differ; run with --run to see the real number).")
        } else {
            print("Returned \(formatBytes(report.hostDelta)) to macOS (host free: \(formatBytes(report.hostFreeBefore)) \u{2192} \(formatBytes(report.hostFreeAfter)))")

            let entry = HistoryEntry(
                date: Date(),
                backend: report.backend,
                imagesReclaimed: report.steps.first(where: { $0.name == "images" })?.dockerReportedBytes ?? 0,
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
