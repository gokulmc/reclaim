import Foundation
import ReclaimKit

struct CLIError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Detects the live backend, or throws a helpful error if none is running.
func detectBackendOrThrow() throws -> DetectedBackend {
    let detected = BackendDetector.detect()
    guard let first = detected.first else {
        throw CLIError(message: """
        No running Docker backend detected (checked Colima, OrbStack, Rancher Desktop, Docker Desktop).
        Is Colima/Docker running? Try `colima start`.
        """)
    }
    return first
}

/// Pads a string with trailing spaces to `width` (never truncates).
func pad(_ string: String, _ width: Int) -> String {
    let count = string.count
    guard count < width else { return string + " " }
    return string + String(repeating: " ", count: width - count)
}

/// Posts a macOS user notification via `osascript`. The CLI is not an app bundle, so
/// `UNUserNotificationCenter` isn't available to it (see docs/IMPLEMENTATION.md, M4).
func notifyUser(title: String = "Reclaim", message: String) {
    let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")
    let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
    let script = "display notification \"\(escapedMessage)\" with title \"\(escapedTitle)\""
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        FileHandle.standardError.write(Data("warning: failed to post notification: \(error)\n".utf8))
    }
}
