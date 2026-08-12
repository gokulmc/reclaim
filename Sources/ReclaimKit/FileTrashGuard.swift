import Foundation

/// `FileTrashGuard` is the large-files-feature analogue of `CacheSafetyGuard`: an independent
/// enforcement layer standing between a scanned `LargeItem` and any real move-to-Trash call
/// (`FileTrasher`, arriving in a later milestone). It mirrors `CacheSafetyGuard`'s STRUCTURE —
/// canonicalize `home` and `target` via `.resolvingSymlinksInPath().standardizedFileURL` before
/// every comparison, reject an original (pre-resolution) symlink target outright, and enforce
/// the component-boundary "strictly under home" check — but its denylist is **inverted**.
///
/// `CacheSafetyGuard` protects a narrow catalog of regenerable dev-tool caches, so it blocks
/// broad user-data locations (`Documents`, `Desktop`, all of `Library`) because nothing in that
/// catalog should ever legitimately need to reach them. This feature exists for the opposite
/// reason: the user is deliberately choosing to trash their own big files and folders —
/// including ones living inside `Documents`/`Desktop`/`Downloads`/`Movies`/... — because that is
/// the whole point of a disk-space finder. Blocking those would defeat the feature. So the
/// denylist here is narrow by design: it rejects only (a) the personal-folder ROOTS themselves
/// (trashing the entirety of `~/Documents` in one shot is almost certainly a mistake, even
/// though a big file *inside* it is exactly what this feature is for), and (b) a short list of
/// subtrees whose loss is catastrophic or effectively irreversible in a way plain
/// Trash-recoverability doesn't fully offset — app state (`Library/Application Support`,
/// `Library/Containers`, ...), credentials (`.ssh`, `.gnupg`, `.aws`, ...), and
/// container/VM-managed data (`.colima`, `.docker`, `.orbstack`, `.rd`, ...) whose disappearance
/// can corrupt a running daemon or destroy containers outright, not merely lose a file the user
/// can drag back out of the Trash.
///
/// **Move-to-Trash recoverability is the primary safety net for this whole feature.**
/// `FileManager`'s move-to-Trash API (the sole real-deletion call site, landing in `FileTrasher`
/// in a later milestone) moves items to `~/.Trash`, not permanent deletion — a mis-selected file
/// can always be pulled back out. This guard exists only to block the handful of targets where
/// even that recoverability isn't good enough: the filesystem root, `$HOME` itself, anything
/// outside `$HOME` or crossing a volume boundary, and the catastrophic/irreversible subtrees
/// above.
///
/// Unlike `CacheSafetyGuard`, there is deliberately **no depth-≥2 floor**: a depth-1 target
/// directly under home — `~/big.dmg`, `~/projects` — is exactly the kind of legitimately
/// reclaimable item this feature exists to surface, and it is just as Trash-recoverable as
/// anything found deeper in the tree.
public enum FileTrashGuard {
    public struct Violation: Error, Equatable, CustomStringConvertible {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }

        public var description: String {
            "FileTrashGuard blocked \(path): \(reason)"
        }
    }

    /// Protected personal-folder ROOTS, relative to `home` — rejected only on exact equality.
    /// Everything inside one of these (a big file, a big subfolder) is allowed; only wholesale
    /// removal of the root itself is blocked. `.Trash` is additionally covered (root AND
    /// children) by `protectedSubtreeRelativePaths` below.
    private static let protectedRootRelativePaths = [
        "Documents",
        "Desktop",
        "Downloads",
        "Movies",
        "Music",
        "Pictures",
        "Public",
        "Library",
        "Applications",
        "Sites",
        ".Trash"
    ]

    /// Protected SUBTREES, relative to `home` — rejected if the target is equal to, or nested
    /// anywhere under, one of these. App state, credentials, and container/VM-managed data
    /// whose loss is catastrophic in a way Trash-recoverability doesn't fully offset; `.Trash`
    /// itself is included so this feature can never be used to "trash the Trash".
    private static let protectedSubtreeRelativePaths = [
        "Library/Application Support",
        "Library/Preferences",
        "Library/Keychains",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Mobile Documents",
        "Library/CloudStorage",
        "Library/Application Support/Reclaim",
        ".ssh",
        ".gnupg",
        ".aws",
        ".config",
        ".kube",
        ".docker",
        ".colima",
        ".orbstack",
        ".rd",
        ".Trash"
    ]

    /// Validates that `target` is safe to trash. Throws `Violation` with a rule-specific reason
    /// the moment any check fails; every check must otherwise pass for `validate` to return
    /// normally. Rule order (first failure wins):
    /// 1. the ORIGINAL (pre-canonicalization) target must not itself be a symbolic link;
    /// 2. canonicalize `home` and `target`;
    /// 3. never the filesystem root;
    /// 4. never `home` itself;
    /// 5. must be strictly under `home` (component-boundary prefix);
    /// 6. never a path mentioning "volume";
    /// 7. never equal to a protected personal-folder root (children allowed);
    /// 8. never equal to, or nested under, a protected subtree;
    /// 9. otherwise allow.
    public static func validate(target: URL, home: String) throws {
        let originalPath = target.path

        // Rule 1: the ORIGINAL target must not itself be a symbolic link — resolving through it
        // and trashing whatever it points at would trash something the caller never actually
        // chose.
        let originalIsSymlink = (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        if originalIsSymlink {
            throw Violation(path: originalPath, reason: "target is itself a symbolic link — refusing to resolve-then-trash through it")
        }

        // Rule 2: canonicalize everything else FIRST — every comparison below happens on the
        // symlink-free, standardized form, defending against a TOCTOU symlink-swap between scan
        // and trash.
        let canonicalHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL
        let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL

        // Rule 3: never the filesystem root.
        if canonicalTarget.pathComponents == ["/"] {
            throw Violation(path: originalPath, reason: "target resolves to the filesystem root")
        }

        // Rule 4: never $HOME itself.
        if canonicalTarget == canonicalHome {
            throw Violation(path: originalPath, reason: "target resolves to the home directory itself")
        }

        let targetComponents = canonicalTarget.pathComponents
        let homeComponents = canonicalHome.pathComponents

        // Rule 5: strictly UNDER home — home must be a proper prefix of target on a
        // path-component boundary (not merely a string prefix, and not equal).
        guard targetComponents.count > homeComponents.count,
              Array(targetComponents.prefix(homeComponents.count)) == homeComponents else {
            throw Violation(path: originalPath, reason: "target resolves outside the home directory")
        }

        // Rule 6: never a path that mentions a volume — no legitimate large-item target ever
        // needs to cross a volume boundary (e.g. an external drive mounted under /Volumes).
        if canonicalTarget.path.lowercased().contains("volume") {
            throw Violation(path: originalPath, reason: "target path contains \"volume\"")
        }

        // Rule 7: reject EQUALITY of a protected personal-folder root — children are allowed;
        // only wholesale removal of the root is blocked.
        for relativePath in protectedRootRelativePaths {
            let rootComponents = canonicalHome
                .appendingPathComponent(relativePath, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .pathComponents
            if targetComponents == rootComponents {
                throw Violation(path: originalPath, reason: "target is the protected folder root \"\(relativePath)\"")
            }
        }

        // Rule 8: reject target equal-to-OR-under a protected subtree — app state, credentials,
        // and container/VM-managed data where even Trash-recoverability isn't enough.
        for relativePath in protectedSubtreeRelativePaths {
            let subtreeComponents = canonicalHome
                .appendingPathComponent(relativePath, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .pathComponents
            let targetIsEqualToOrUnderSubtree =
                targetComponents.count >= subtreeComponents.count &&
                Array(targetComponents.prefix(subtreeComponents.count)) == subtreeComponents
            if targetIsEqualToOrUnderSubtree {
                throw Violation(path: originalPath, reason: "target is, or is under, the protected path \"\(relativePath)\"")
            }
        }

        // Rule 9: else allow — return normally.
    }
}
