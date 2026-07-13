import Foundation

/// Detects which Docker backend(s) are currently live on this machine.
///
/// Detection order matches docs/IMPLEMENTATION.md: colima, orbstack, rancherDesktop,
/// dockerDesktop. A candidate socket only counts as "live" if it exists on disk **and**
/// answers `GET /_ping` with `OK` (SPEC.md §4) — a stale socket file left behind by a backend
/// that's no longer running must not be reported as detected.
///
/// `baseDirectory` defaults to the real home directory but is overridable so tests can point
/// detection at a temp directory containing a fake socket, instead of the real `~`.
public enum BackendDetector {
    public static func detect(baseDirectory: String = NSHomeDirectory()) -> [DetectedBackend] {
        let candidates: [(Backend, String)] = [
            (.colima, baseDirectory + "/.colima/default/docker.sock"),
            (.orbstack, baseDirectory + "/.orbstack/run/docker.sock"),
            (.rancherDesktop, baseDirectory + "/.rd/docker.sock"),
            (.dockerDesktop, baseDirectory + "/Library/Containers/com.docker.docker/Data/docker-cli.sock")
        ]

        var detected: [DetectedBackend] = []
        for (backend, socketPath) in candidates {
            guard FileManager.default.fileExists(atPath: socketPath) else { continue }
            guard respondsToPing(socketPath: socketPath) else { continue }
            detected.append(DetectedBackend(backend: backend, socketPath: socketPath))
        }
        return detected
    }

    private static func respondsToPing(socketPath: String) -> Bool {
        let client = UnixHTTPClient(socketPath: socketPath)
        guard let response = try? client.requestSync(method: "GET", path: "/_ping") else { return false }
        guard response.statusCode == 200 else { return false }
        let text = String(data: response.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "OK"
    }
}
