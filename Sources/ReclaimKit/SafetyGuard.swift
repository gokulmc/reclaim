import Foundation

/// `SafetyGuard` is the enforcement half of a design property (see docs/IMPLEMENTATION.md):
/// `DockerClient`'s request path is `private`, its only public entry points are the fixed
/// methods documented in the ReclaimKit API surface, and there is no method anywhere that
/// deletes a volume — the call is unrepresentable. `SafetyGuard.validate` is the second,
/// independent layer: every outgoing request is checked here before it leaves the process,
/// and any mutating (`POST`/`DELETE`) request whose path touches a volume, or any
/// `system/prune`, is rejected — even if a future change to `DockerClient` accidentally
/// introduced one.
///
/// This is the one rule in the whole app that must never regress (SPEC.md §2): a volume
/// prune can silently delete a running database. See the source-grep regression test in
/// ReclaimKitTests, which asserts the literal path fragment this guards against never
/// appears anywhere in `Sources/`.
public enum SafetyGuard {
    public struct Violation: Error, Equatable, CustomStringConvertible {
        public let method: String
        public let path: String

        public var description: String {
            "SafetyGuard blocked \(method) \(path): volume-destructive and system-wide prune calls are never allowed"
        }
    }

    /// Validates an outgoing request before it is sent. Throws `Violation` if the request is
    /// a mutating call that touches a volume, or a `system/prune` call.
    ///
    /// Note on a deliberate deviation from docs/IMPLEMENTATION.md's wording ("throws, and
    /// assertionFailures in debug"): Swift's `assertionFailure` traps the process when
    /// assertions are enabled, which is exactly the configuration `swift test` builds in by
    /// default — so a literal `assertionFailure` here would crash the test binary the moment
    /// the mandatory SafetyGuard rejection tests exercised it, and is a silent no-op in a
    /// `-c release` build (assertions are stripped) where it would matter most for a shipped
    /// binary. The `throw` below is unconditional in every build configuration and is what
    /// both `DockerClient` and the test suite actually rely on, so it is the sole enforcement
    /// mechanism here.
    public static func validate(method: String, path: String) throws {
        let upperMethod = method.uppercased()
        guard upperMethod == "POST" || upperMethod == "DELETE" else {
            // Reads (GET) are always safe — this is how volumes are listed read-only.
            return
        }

        let lowerPath = path.lowercased()

        if lowerPath.contains("volume") {
            throw Violation(method: method, path: path)
        }

        if lowerPath.contains("system/prune") {
            throw Violation(method: method, path: path)
        }
    }
}
