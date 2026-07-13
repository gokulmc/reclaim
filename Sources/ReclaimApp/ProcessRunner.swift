import Foundation

/// A tiny app-local process runner for the one ad-hoc shell-out the UI needs directly
/// ("Start Colima", streamed into the progress log — docs/IMPLEMENTATION.md, App M1-M4). This
/// deliberately does not reach into `ReclaimKit.TrimService`'s private process-execution
/// internals; it mirrors the same PATH handling (SPEC.md §7: a GUI app does not inherit the
/// user's shell PATH, and `colima` typically lives in `/opt/homebrew/bin`) as its own small,
/// self-contained helper.
enum ProcessRunner {
    static let processPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    struct Outcome {
        let exitCode: Int32
    }

    /// Runs `command arguments...`, forwarding each stdout/stderr line to `progress` as it
    /// arrives. Never throws — a launch failure is reported through `progress` and an
    /// exit code of `-1`, so callers can always drive their UI state from the returned outcome
    /// alone.
    @discardableResult
    static func run(
        command: String,
        arguments: [String],
        progress: @escaping @Sendable (String) -> Void
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = processPATH
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let forward: @Sendable (FileHandle) -> Void = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    progress(String(line))
                }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = forward
            stderrPipe.fileHandleForReading.readabilityHandler = forward

            process.terminationHandler = { finished in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: Outcome(exitCode: finished.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                progress("Failed to launch \(command): \(error.localizedDescription)")
                continuation.resume(returning: Outcome(exitCode: -1))
            }
        }
    }
}
