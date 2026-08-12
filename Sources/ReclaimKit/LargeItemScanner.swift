import Foundation

/// Recursively walks `home`, ranking the biggest files and folders found. Read-only: it only
/// measures the filesystem, never deletes or moves anything (deletion arrives in a later
/// milestone via `FileTrasher`/`LargeFilesReclaimer`, both independent call sites gated by
/// `FileTrashGuard`).
///
/// The walk is a **single-pass recursive DFS**: `walk(dir:depth:...)` returns the subtree's
/// total allocated size, so every folder's reported size is exact (each file counted exactly
/// once, however deep) without a second full-tree pass. Candidates — individual files at or
/// above `fileThresholdBytes`, and folders (or opaque bundles) at or above
/// `folderThresholdBytes` within `folderRankMaxDepth` — are collected as the walk proceeds and
/// capped to `maxFileCandidates`/`maxFolderCandidates` to bound memory on a very large disk.
///
/// `contentsOfDirectory` throws on the TCC-gated locations without Full Disk Access. Unlike
/// `DirectorySizer.size(of:)`, which silently continues past enumerator errors, this scanner
/// RECORDS the unreadable directory's path in `skippedAreas` — the FDA-gap fix: a whole-home
/// scan must be honest about what it couldn't see rather than silently under-reporting.
///
/// `scan` is a plain `async` function that never spawns child tasks, so every `Task.isCancelled`
/// check made during the (synchronous) recursive walk reads the flag of the CALLER's task —
/// cancelling that task deterministically stops the walk.
public struct LargeItemScanner {
    public struct Configuration {
        public var fileThresholdBytes: Int64
        public var folderThresholdBytes: Int64
        public var folderRankMaxDepth: Int
        public var maxFileCandidates: Int
        public var maxFolderCandidates: Int
        public var excludedRelativePaths: [String]
        public var opaqueBundleExtensions: Set<String>

        public init(
            fileThresholdBytes: Int64 = 100 * 1024 * 1024,
            folderThresholdBytes: Int64 = 250 * 1024 * 1024,
            folderRankMaxDepth: Int = 2,
            maxFileCandidates: Int = 300,
            maxFolderCandidates: Int = 200,
            excludedRelativePaths: [String] = [".Trash", "Library/Application Support/Reclaim"],
            opaqueBundleExtensions: Set<String> = [
                "app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary",
                "framework", "bundle", "xcappdata"
            ]
        ) {
            self.fileThresholdBytes = fileThresholdBytes
            self.folderThresholdBytes = folderThresholdBytes
            self.folderRankMaxDepth = folderRankMaxDepth
            self.maxFileCandidates = maxFileCandidates
            self.maxFolderCandidates = maxFolderCandidates
            self.excludedRelativePaths = excludedRelativePaths
            self.opaqueBundleExtensions = opaqueBundleExtensions
        }

        public static let `default` = Configuration()
    }

    private let home: String
    private let homeURL: URL
    private let configuration: Configuration

    public init(home: String = NSHomeDirectory(), configuration: Configuration = .default) {
        self.home = home
        self.homeURL = URL(fileURLWithPath: home)
        self.configuration = configuration
    }

    /// Mutable state accumulated across one `scan` call's recursive walk. Confined to a single
    /// (synchronous, non-parallel) call stack — never shared across tasks or threads.
    private final class WalkState {
        var fileCandidates: [LargeItem] = []
        var folderCandidates: [LargeItem] = []
        var skippedAreas: [String] = []
        var filesScanned = 0
        var wasCancelled = false
        var lastProgressFileCount = 0
        var lastProgressArea = ""
    }

    public func scan(progress: @escaping (LargeScanProgress) -> Void = { _ in }) async -> LargeScanResult {
        let state = WalkState()
        _ = walk(homeURL, relativePath: "", depth: 0, state: state, progress: progress)

        state.fileCandidates.sort { $0.sizeBytes > $1.sizeBytes }
        if state.fileCandidates.count > configuration.maxFileCandidates {
            state.fileCandidates = Array(state.fileCandidates.prefix(configuration.maxFileCandidates))
        }
        state.folderCandidates.sort { $0.sizeBytes > $1.sizeBytes }
        if state.folderCandidates.count > configuration.maxFolderCandidates {
            state.folderCandidates = Array(state.folderCandidates.prefix(configuration.maxFolderCandidates))
        }

        var merged = state.fileCandidates + state.folderCandidates
        merged.sort { $0.sizeBytes > $1.sizeBytes }

        let stamped = merged.map { item -> LargeItem in
            do {
                try FileTrashGuard.validate(target: item.url, home: home)
                return item
            } catch {
                return LargeItem(
                    id: item.id,
                    url: item.url,
                    path: item.path,
                    sizeBytes: item.sizeBytes,
                    isDirectory: item.isDirectory,
                    isProtected: true
                )
            }
        }

        return LargeScanResult(
            items: stamped,
            skippedAreas: state.skippedAreas,
            filesScanned: state.filesScanned,
            wasCancelled: state.wasCancelled
        )
    }

    /// Returns the total allocated size of everything readable under `dir` (each file counted
    /// once, however deep). Symbolic links are skipped entirely — never followed, never
    /// counted. A `contentsOfDirectory` throw records `dir` in `skippedAreas` and returns 0 for
    /// that subtree rather than propagating — an FDA gap in one area must not abort the whole
    /// scan.
    ///
    /// `relativePath` is threaded down explicitly (rather than re-derived from `child.path` by
    /// stripping a `home` prefix) because on macOS `/var` — and so `NSTemporaryDirectory()`,
    /// which many callers (including tests) pass as `home` — is itself a symlink to
    /// `/private/var`. `FileManager.contentsOfDirectory` resolves that symlink when it builds
    /// child URLs, so a child's absolute path does not always share a literal string prefix
    /// with the unresolved `home` it was reached from. Carrying the relative path alongside the
    /// walk sidesteps that mismatch entirely.
    private func walk(
        _ dir: URL,
        relativePath: String,
        depth: Int,
        state: WalkState,
        progress: @escaping (LargeScanProgress) -> Void
    ) -> Int64 {
        // Checked BEFORE any filesystem I/O so cancellation is observed as early as possible —
        // including for an already-cancelled task walking an empty (or not-yet-read) directory.
        if Task.isCancelled {
            state.wasCancelled = true
            return 0
        }

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: resourceKeys,
                options: []
            )
        } catch {
            state.skippedAreas.append(dir.path)
            return 0
        }

        let keySet = Set(resourceKeys)
        var subtotal: Int64 = 0

        for child in children {
            if Task.isCancelled {
                state.wasCancelled = true
                return subtotal
            }

            guard let values = try? child.resourceValues(forKeys: keySet) else { continue }

            // Never follow a symlink: don't descend into it and don't count it.
            if values.isSymbolicLink == true {
                continue
            }

            let childName = child.lastPathComponent
            let childRelativePath = relativePath.isEmpty ? childName : "\(relativePath)/\(childName)"

            if configuration.excludedRelativePaths.contains(childRelativePath) {
                continue
            }

            let area = areaComponent(of: childRelativePath)

            if values.isRegularFile == true {
                let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
                subtotal += bytes
                state.filesScanned += 1
                reportProgressIfNeeded(state: state, area: area, progress: progress)

                if bytes >= configuration.fileThresholdBytes {
                    addCandidate(&state.fileCandidates, item: makeItem(url: child, bytes: bytes, isDirectory: false), cap: configuration.maxFileCandidates)
                }
                continue
            }

            guard values.isDirectory == true else { continue }

            // An "opaque bundle" (a .app, a .photoslibrary, ...) is sized as one unit and never
            // descended into — its internals aren't independently reclaimable by the user.
            if configuration.opaqueBundleExtensions.contains(child.pathExtension.lowercased()) {
                let bytes = DirectorySizer.size(of: child)
                subtotal += bytes
                if bytes >= configuration.folderThresholdBytes {
                    addCandidate(&state.folderCandidates, item: makeItem(url: child, bytes: bytes, isDirectory: true), cap: configuration.maxFolderCandidates)
                }
                continue
            }

            let childTotal = walk(child, relativePath: childRelativePath, depth: depth + 1, state: state, progress: progress)
            subtotal += childTotal
            if state.wasCancelled {
                return subtotal
            }
            if childTotal >= configuration.folderThresholdBytes && depth + 1 <= configuration.folderRankMaxDepth {
                addCandidate(&state.folderCandidates, item: makeItem(url: child, bytes: childTotal, isDirectory: true), cap: configuration.maxFolderCandidates)
            }
        }

        return subtotal
    }

    private func reportProgressIfNeeded(state: WalkState, area: String, progress: @escaping (LargeScanProgress) -> Void) {
        let areaChanged = area != state.lastProgressArea
        let hitCountThreshold = state.filesScanned - state.lastProgressFileCount >= 2_000
        guard areaChanged || hitCountThreshold else { return }
        state.lastProgressFileCount = state.filesScanned
        state.lastProgressArea = area
        progress(LargeScanProgress(filesScanned: state.filesScanned, currentArea: area))
    }

    /// Appends `item` and, once the list has grown well past `cap`, sorts and trims it — bounds
    /// peak memory during the walk of a very large disk without requiring a sort on every
    /// append. `scan` performs one final authoritative sort + trim regardless.
    private func addCandidate(_ list: inout [LargeItem], item: LargeItem, cap: Int) {
        list.append(item)
        if list.count > cap * 2 {
            list.sort { $0.sizeBytes > $1.sizeBytes }
            list = Array(list.prefix(cap))
        }
    }

    private func makeItem(url: URL, bytes: Int64, isDirectory: Bool) -> LargeItem {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        return LargeItem(
            id: canonical.path,
            url: url,
            path: url.path,
            sizeBytes: bytes,
            isDirectory: isDirectory,
            isProtected: false
        )
    }

    /// The area label used for progress reporting: the depth-1 path component under `home` —
    /// i.e. the first segment of a (non-empty) home-relative path.
    private func areaComponent(of relativePath: String) -> String {
        relativePath.split(separator: "/").first.map(String.init) ?? relativePath
    }
}
