import Foundation

/// `CacheSafetyGuard` is the dev-tool-cache analogue of `SafetyGuard`: a second, independent
/// enforcement layer standing between the cache catalog and the filesystem. `CacheDeleter`
/// (the only real-deletion call site in `Sources/`) must call `validate` before
/// every deletion, exactly as `DockerClient.send` calls `SafetyGuard.validate` before every
/// request.
///
/// The central defense here is **symlink resolution**. A catalog path like `~/.npm` is only
/// ever safe to delete because, at scan time, it is known to sit under `$HOME`. But nothing
/// stops a hostile or buggy tool from replacing `~/.npm` with a symlink to `/` — or to another
/// user's home directory, or to `/Volumes/SomeExternalDrive` — between the scan and the
/// delete (a classic TOCTOU / symlink-swap attack). `validate` defends against this by
/// resolving `target`, `home`, and every `allowedRoot` to their canonical, symlink-free form
/// with `.resolvingSymlinksInPath().standardizedFileURL` *before* any comparison, so a
/// poisoned symlink planted at a catalog path can never redirect a delete outside `$HOME`.
/// The *original* (pre-resolution) target is separately checked and rejected outright if it
/// is itself a symlink — resolving through it and deleting the resolved target would still
/// mean the delete lands somewhere the caller never actually chose.
public enum CacheSafetyGuard {
    public struct Violation: Error, Equatable, CustomStringConvertible {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }

        public var description: String {
            "CacheSafetyGuard blocked \(path): \(reason)"
        }
    }

    /// Hardcoded, relative to `home` — never deleted even if a caller mistakenly includes one
    /// of these (or an ancestor of one) in `allowedRoots`. `Documents` and `Desktop` hold
    /// arbitrary user data; `Library` and `Library/Application Support` are themselves far too
    /// broad (countless unrelated apps' data lives directly under them — no cache catalog
    /// entry should ever be "the whole of Library"); `Library/Application Support/Reclaim` is
    /// this app's own history store, which must never be able to delete itself.
    private static let denylistRelativePaths = [
        "Documents",
        "Desktop",
        "Library",
        "Library/Application Support",
        "Library/Application Support/Reclaim"
    ]

    /// Validates that `target` is safe to delete: strictly under `home`, within at least one
    /// of `allowedRoots`, at a sane depth, free of any "volume" mention, not a symlink itself,
    /// and not equal to (or an ancestor of) a hardcoded denylist entry. Throws `Violation`
    /// with a rule-specific reason the moment any check fails; every check must otherwise pass
    /// for `validate` to return normally.
    public static func validate(target: URL, home: String, allowedRoots: [URL]) throws {
        let originalPath = target.path

        // Rule: the ORIGINAL (pre-canonicalization) target must not itself be a symbolic
        // link. Resolving through it and deleting whatever it points at would delete
        // something the catalog never actually vetted.
        let originalIsSymlink = (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        if originalIsSymlink {
            throw Violation(path: originalPath, reason: "target is itself a symbolic link — refusing to resolve-then-delete through it")
        }

        // Canonicalize everything else FIRST — this is the key defense described above.
        let canonicalHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL
        let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL
        let canonicalAllowedRoots = allowedRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }

        // Rule: never the filesystem root.
        if canonicalTarget.pathComponents == ["/"] {
            throw Violation(path: originalPath, reason: "target resolves to the filesystem root")
        }

        // Rule: never $HOME itself.
        if canonicalTarget == canonicalHome {
            throw Violation(path: originalPath, reason: "target resolves to the home directory itself")
        }

        let targetComponents = canonicalTarget.pathComponents
        let homeComponents = canonicalHome.pathComponents

        // Rule: strictly UNDER home — home must be a proper prefix of target on a
        // path-component boundary (not merely a string prefix, and not equal).
        guard targetComponents.count > homeComponents.count,
              Array(targetComponents.prefix(homeComponents.count)) == homeComponents else {
            throw Violation(path: originalPath, reason: "target resolves outside the home directory")
        }

        // Rule: at least 2 path components below home — refuses `~/Library`-style top-level
        // directories that are too broad to ever delete wholesale. The one deliberate carve-out:
        // a target that resolves to EXACTLY one of the caller's own `allowedRoots` (i.e. it IS a
        // defined, single-directory cache catalog root verbatim — e.g. `~/.npm`, one path
        // component below home) is exempt from this floor, since that root was explicitly
        // vetted by the catalog rather than merely being "under" something broad. A shallow
        // directory that is NOT itself an exact catalog root (an accidental `~/Library` entry,
        // or an arbitrary caller-supplied path) still hits this floor — and known-dangerous
        // shallow directories are additionally caught unconditionally by the denylist below.
        let depthBelowHome = targetComponents.count - homeComponents.count
        let isExactAllowedRoot = canonicalAllowedRoots.contains { $0.pathComponents == targetComponents }
        guard depthBelowHome >= 2 || isExactAllowedRoot else {
            throw Violation(path: originalPath, reason: "target is only \(depthBelowHome) path component(s) below home; refusing a too-broad top-level directory")
        }

        // Rule: hardcoded denylist — never equal to, nor an ancestor of, one of the protected
        // locations below. Checked independently of `allowedRoots` so a catalog mistake can
        // never authorize deleting one of these.
        for relativePath in denylistRelativePaths {
            let denylistComponents = canonicalHome
                .appendingPathComponent(relativePath, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .pathComponents
            let targetIsEqualToOrAncestorOfDenylistEntry =
                targetComponents.count <= denylistComponents.count &&
                Array(denylistComponents.prefix(targetComponents.count)) == targetComponents
            if targetIsEqualToOrAncestorOfDenylistEntry {
                throw Violation(path: originalPath, reason: "target is, or contains, the protected path \"\(relativePath)\"")
            }
        }

        // Rule: never a path that mentions a volume — mirrors `SafetyGuard`'s Docker
        // volume rejection; no legitimate cache definition ever needs to cross a volume
        // boundary (e.g. an external drive mounted under `/Volumes`).
        if canonicalTarget.path.lowercased().contains("volume") {
            throw Violation(path: originalPath, reason: "target path contains \"volume\"")
        }

        // Rule: must be within (equal to or under) at least one known catalog root.
        let withinAllowedRoot = canonicalAllowedRoots.contains { root in
            let rootComponents = root.pathComponents
            return targetComponents.count >= rootComponents.count
                && Array(targetComponents.prefix(rootComponents.count)) == rootComponents
        }
        guard withinAllowedRoot else {
            throw Violation(path: originalPath, reason: "target is not within any known cache catalog root")
        }
    }
}
