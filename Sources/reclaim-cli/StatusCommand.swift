import ArgumentParser
import Foundation
import ReclaimKit

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the detected backend, host disk free/total, and a Docker usage breakdown."
    )

    func run() async throws {
        let detected = try detectBackendOrThrow()
        let client = DockerClient(socketPath: detected.socketPath)

        let df = try await client.systemDF()
        let disk = try DiskProbe.stat()
        let volumes = try await client.listVolumes()

        print("Backend: \(detected.backend.displayName)  (\(detected.socketPath))")
        print("Host disk: \(formatBytes(disk.freeBytes)) free of \(formatBytes(disk.totalBytes))")
        print("")
        print("Docker usage breakdown (build cache first — it's usually the big one):")
        print(pad("  CATEGORY", 28) + pad("TOTAL", 14) + "RECLAIMABLE")
        print(pad("  Build cache", 28) + pad(formatBytes(df.buildCacheTotalSize), 14) + formatBytes(df.buildCacheReclaimableSize))
        print(pad("  Images", 28) + pad(formatBytes(df.imagesTotalSize), 14) + formatBytes(df.imagesReclaimableSize))
        print(pad("  Containers (stopped)", 28) + pad(formatBytes(df.stoppedContainersSize), 14) + "\(df.stoppedContainersCount) stopped")
        print(pad("  Volumes (protected)", 28) + pad(formatBytes(df.volumesTotalSize), 14) + "read-only, never touched")
        print("")
        print("Volumes: \(volumes.count) total — always read-only, never pruned by Reclaim.")
    }
}
