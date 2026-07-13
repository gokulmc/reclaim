import ArgumentParser
import ReclaimKit

struct VolumesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volumes",
        abstract: "List Docker volumes, read-only. Reclaim never deletes or prunes volumes."
    )

    func run() async throws {
        let detected = try detectBackendOrThrow()
        let client = DockerClient(socketPath: detected.socketPath)
        let volumes = try await client.listVolumes()

        print("Volumes on \(detected.backend.displayName): \(volumes.count)\n")
        for volume in volumes.sorted(by: { $0.name < $1.name }) {
            let sizeText = (volume.usageSize.map { $0 >= 0 ? formatBytes($0) : "unknown" }) ?? "unknown"
            print("  \(pad(volume.name, 46)) \(sizeText)")
        }
        print("\nVolumes are protected: read-only everywhere in this app — never touched by Reclaim.")
    }
}
