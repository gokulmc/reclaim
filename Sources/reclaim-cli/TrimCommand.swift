import ArgumentParser
import ReclaimKit

struct TrimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trim",
        abstract: "Run only the fstrim step for the detected backend."
    )

    @Flag(name: .customLong("force-trim"), help: "Docker Desktop only: force the privileged nsenter fstrim fallback.")
    var forceTrim: Bool = false

    func run() async throws {
        let detected = try detectBackendOrThrow()
        print("Backend: \(detected.backend.displayName)")

        let trimService = TrimService()
        do {
            let outcome = try await trimService.trim(backend: detected.backend, forceTrim: forceTrim) { line in
                print("    \(line)")
            }
            switch outcome {
            case .trimmed(let bytes):
                print("Trimmed \(formatBytes(bytes)).")
            case .notNeeded(let reason):
                print(reason)
            }
        } catch TrimError.backendStopped {
            print("Backend is stopped — start it first (e.g. `colima start`).")
        }
    }
}
