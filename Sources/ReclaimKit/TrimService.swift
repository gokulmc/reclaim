import Foundation

/// Result of a trim attempt.
public enum TrimOutcome: Equatable {
    /// `fstrim` ran and reported `bytes` total trimmed across all mounts.
    case trimmed(bytes: Int64)
    /// No trim was necessary/possible for this backend, with a human-readable reason
    /// (OrbStack reclaims natively; Docker Desktop auto-trims when idle).
    case notNeeded(String)
}

public enum TrimError: Error, Equatable, CustomStringConvertible {
    /// The backend's VM isn't running, so there's nothing to `ssh`/`shell` into.
    case backendStopped
    case processLaunchFailed(String)
    case processFailed(String, Int32)

    public var description: String {
        switch self {
        case .backendStopped:
            return "Backend is stopped"
        case .processLaunchFailed(let detail):
            return "Failed to launch process: \(detail)"
        case .processFailed(let command, let exitCode):
            return "\(command) exited with status \(exitCode)"
        }
    }
}

/// Runs the `fstrim` step — the whole differentiator of this app (SPEC.md §1). Docker's own
/// prune frees blocks inside the Linux VM; only `fstrim` (via a discard down to the sparse
/// disk image) actually returns that space to macOS. `fstrim` has no API — it must shell out
/// (SPEC.md §5).
public struct TrimService {
    /// Explicit PATH for every `Process` invocation (SPEC.md §7: a GUI app does not inherit
    /// the user's shell PATH, and `colima`/`docker`/`rdctl` typically live in
    /// `/opt/homebrew/bin`).
    static let processPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public init() {}

    /// Runs the appropriate trim strategy for `backend`, streaming stdout+stderr lines to
    /// `progress` as they arrive (`fstrim` is slow and silent until done — SPEC.md §7).
    ///
    /// - Parameter forceTrim: Docker Desktop only. Recent Docker Desktop versions auto-trim
    ///   when idle, so by default this is a no-op there; passing `true` runs the privileged
    ///   `nsenter` fallback from SPEC.md §4 instead.
    public func trim(
        backend: Backend,
        forceTrim: Bool = false,
        progress: @escaping (String) -> Void = { _ in }
    ) async throws -> TrimOutcome {
        switch backend {
        case .colima:
            try await preflightColimaRunning()
            let lines = try await run(
                command: "colima",
                arguments: ["ssh", "--", "sudo", "fstrim", "-av"],
                progress: progress
            )
            return .trimmed(bytes: Self.parseFstrimBytes(from: lines))

        case .rancherDesktop:
            let lines = try await run(
                command: "rdctl",
                arguments: ["shell", "--", "sudo", "fstrim", "-av"],
                progress: progress
            )
            return .trimmed(bytes: Self.parseFstrimBytes(from: lines))

        case .orbstack:
            return .notNeeded("OrbStack reclaims disk space natively — no trim needed.")

        case .dockerDesktop:
            guard forceTrim else {
                return .notNeeded("Recent Docker Desktop versions TRIM automatically when idle.")
            }
            let lines = try await run(
                command: "docker",
                arguments: [
                    "run", "--rm", "--privileged", "--pid=host", "alpine",
                    "nsenter", "-t", "1", "-m", "-u", "-i", "-n", "fstrim", "-av"
                ],
                progress: progress
            )
            return .trimmed(bytes: Self.parseFstrimBytes(from: lines))
        }
    }

    private func preflightColimaRunning() async throws {
        let result = try await runProcess(command: "colima", arguments: ["status"], progress: { _ in })
        guard result.exitCode == 0 else {
            throw TrimError.backendStopped
        }
    }

    private func run(command: String, arguments: [String], progress: @escaping (String) -> Void) async throws -> [String] {
        let result = try await runProcess(command: command, arguments: arguments, progress: progress)
        guard result.exitCode == 0 else {
            throw TrimError.processFailed("\(command) \(arguments.joined(separator: " "))", result.exitCode)
        }
        return result.lines
    }

    // MARK: - Process execution

    struct ProcessResult {
        let exitCode: Int32
        let lines: [String]
    }

    private func runProcess(
        command: String,
        arguments: [String],
        progress: @escaping (String) -> Void
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = Self.processPATH
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let collector = LineCollector(onLine: progress)

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.handle(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.handle(handle.availableData)
            }

            process.terminationHandler = { finished in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let lines = collector.allLines
                continuation.resume(returning: ProcessResult(exitCode: finished.terminationStatus, lines: lines))
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: TrimError.processLaunchFailed("\(command): \(error.localizedDescription)"))
            }
        }
    }

    /// Thread-safe accumulator for stdout/stderr lines arriving from `Pipe` readability
    /// handlers (which fire on an arbitrary background queue), forwarding each new line to
    /// the caller's progress callback as it arrives.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private let onLine: (String) -> Void

        init(onLine: @escaping (String) -> Void) {
            self.onLine = onLine
        }

        func handle(_ data: Data) {
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let newLines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            guard !newLines.isEmpty else { return }
            lock.lock()
            lines.append(contentsOf: newLines)
            lock.unlock()
            for line in newLines { onLine(line) }
        }

        var allLines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    // MARK: - fstrim output parsing

    /// Parses total trimmed bytes from `fstrim -v` output lines of the form
    /// `<mount>: X GiB (Y bytes) trimmed on <dev>`, summing the `(Y bytes)` capture across
    /// every mount line. Lines without the parenthesized byte count are tolerated by
    /// converting the human-readable size instead.
    static func parseFstrimBytes(from lines: [String]) -> Int64 {
        var total: Int64 = 0
        for line in lines {
            if let bytes = parseParenthesizedBytes(line) {
                total += bytes
            } else if let bytes = parseHumanSizeTrimmed(line) {
                total += bytes
            }
        }
        return total
    }

    private static let parenthesizedBytesRegex = try! NSRegularExpression(
        pattern: #"\(([0-9]+)\s*bytes\)\s*trimmed"#
    )

    static func parseParenthesizedBytes(_ line: String) -> Int64? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = parenthesizedBytesRegex.firstMatch(in: line, range: range),
              let numberRange = Range(match.range(at: 1), in: line),
              let value = Int64(line[numberRange]) else {
            return nil
        }
        return value
    }

    private static let humanSizeRegex = try! NSRegularExpression(
        pattern: #":\s*([0-9]+(?:\.[0-9]+)?)\s*(TiB|GiB|MiB|KiB|B)\s*trimmed"#
    )

    static func parseHumanSizeTrimmed(_ line: String) -> Int64? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = humanSizeRegex.firstMatch(in: line, range: range),
              let numberRange = Range(match.range(at: 1), in: line),
              let unitRange = Range(match.range(at: 2), in: line),
              let value = Double(line[numberRange]) else {
            return nil
        }
        let unit = String(line[unitRange])
        let multiplier: Double
        switch unit {
        case "TiB": multiplier = 1024 * 1024 * 1024 * 1024
        case "GiB": multiplier = 1024 * 1024 * 1024
        case "MiB": multiplier = 1024 * 1024
        case "KiB": multiplier = 1024
        default: multiplier = 1
        }
        return Int64((value * multiplier).rounded())
    }
}
