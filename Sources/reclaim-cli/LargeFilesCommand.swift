import ArgumentParser
import Foundation
import ReclaimKit

/// `reclaim-cli largefiles` — scans the whole `$HOME` for the biggest files and folders
/// (`LargeItemScanner`) and, as of M-LF6, can move a selection of them to the Trash
/// (`LargeFilesReclaimer` → `FileTrasher`, the sole real move-to-Trash call site).
///
/// This is the app's first CLI surface that can delete (well — Trash, recoverably) arbitrary
/// user files, so it mirrors `CachesCommand`'s "read-only listing by default, an explicit flag
/// to act" posture as closely as possible: without `--trash` this is exactly a read-only
/// listing — nothing is scanned for deletion, nothing is moved. `--trash` requires an explicit,
/// non-empty selection (`--only` and/or positional paths, unioned together) — there is no
/// "trash everything" default, and every selected path is validated against the just-completed
/// scan (present AND not protected) before anything real happens.
struct LargeFilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "largefiles",
        abstract: "Scan your home folder for the biggest files and folders and their sizes.",
        discussion: """
        Read-only by default: scans $HOME (Full Disk Access permitting) and lists the largest
        files and folders found, ranked by size, with protected locations marked. Pass --trash
        with a selection (--only <path> and/or one or more positional paths) to actually move
        the selected items to the Trash — recoverable, never a permanent delete.

        Only paths that appear in the just-completed scan and are not protected can be trashed;
        an arbitrary typed path that wasn't scanned/selectable is rejected and nothing is moved.
        """
    )

    /// How many ranked rows to print in the read-only listing.
    private static let defaultListLimit = 20

    @Flag(name: .customLong("trash"), help: "Actually move the selected items to the Trash (recoverable). Without this flag, largefiles only lists what's on disk.")
    var doTrash: Bool = false

    @Option(name: .customLong("only"), help: "Select an item by path (repeatable, ~/... or absolute). Combine with --trash to move it to the Trash.")
    var only: [String] = []

    @Argument(help: "Paths to select — an alternative (or addition) to --only.")
    var paths: [String] = []

    @Flag(name: .customLong("files-only"), help: "List/select only large files, not folders.")
    var filesOnly: Bool = false

    @Flag(name: .customLong("folders-only"), help: "List/select only large folders, not files.")
    var foldersOnly: Bool = false

    @Option(name: .customLong("limit"), help: "How many ranked rows to list.")
    var limit: Int = LargeFilesCommand.defaultListLimit

    @Flag(name: .customLong("notify"), help: "Post a macOS notification with the result (intended for scheduled runs).")
    var notify: Bool = false

    func run() async throws {
        if doTrash {
            try await runTrash()
        } else {
            await printListing()
        }
    }

    // MARK: - Listing (default, read-only)

    private func printListing() async {
        print("Scanning your home folder… (this can take a minute)")
        let scan = await LargeItemScanner().scan()

        var filtered = scan.items
        if filesOnly {
            filtered = filtered.filter { !$0.isDirectory }
        }
        if foldersOnly {
            filtered = filtered.filter { $0.isDirectory }
        }

        let shown = Array(filtered.prefix(max(limit, 0)))

        print("")
        print("Large files & folders in your home directory — read-only listing (nothing is deleted):")
        print("")
        print(pad("  TYPE", 8) + pad("PATH", 64) + pad("SIZE", 12))

        for item in shown {
            let kind = item.isDirectory ? "📁" : "📄"
            let marker = item.isProtected ? "🔒 protected" : ""
            print(pad("  " + kind, 8) + pad(homeRelative(item.path), 64) + pad(formatBytes(item.sizeBytes), 12) + marker)
        }

        print("")
        print("Showing \(shown.count) of \(filtered.count) item(s) found (\(scan.filesScanned) files scanned).")

        if !scan.skippedAreas.isEmpty {
            print("")
            print("Some areas were skipped (Full Disk Access needed) — grant it in System Settings › Privacy › Full Disk Access to include Desktop, Documents, iCloud, etc.")
        }

        print("")
        print("Listing only — pass `--trash <path>` (or `--trash --only <path>`) to move items to the Trash (recoverable).")
    }

    // MARK: - Trash (real move, requires an explicit, scan-validated selection)

    private func runTrash() async throws {
        var seen = Set<String>()
        var rawPaths: [String] = []
        for candidate in only + paths where !seen.contains(candidate) {
            seen.insert(candidate)
            rawPaths.append(candidate)
        }

        guard !rawPaths.isEmpty else {
            throw CLIError(message: """
            No paths selected. Pass one or more paths (positional or --only) to trash, e.g.:
              reclaim-cli largefiles --trash ~/Downloads/big.zip
              reclaim-cli largefiles --trash --only ~/Movies/old.mov --only ~/big.dmg
            """)
        }

        print("Scanning your home folder… (this can take a minute)")
        let scan = await LargeItemScanner().scan()

        let selection = try resolveSelection(rawPaths: rawPaths, scan: scan)

        print("Large files & folders — moving \(selection.count) selected item(s) to the Trash:")
        print("")

        let reclaimer = LargeFilesReclaimer()
        let report = try await reclaimer.trash(selection: selection, options: CleanOptions(dryRun: false)) { event in
            switch event {
            case .step(let text):
                print("==> \(text)")
            case .log(let text):
                print("    \(text)")
            case .done:
                break
            }
        }

        print("")
        print("Moved \(formatBytes(report.hostDelta)) to Trash (recoverable) · host free \(formatBytes(report.hostFreeBefore)) \u{2192} \(formatBytes(report.hostFreeAfter))")

        let entry = HistoryEntry(
            date: Date(),
            backend: nil,
            imagesReclaimed: 0,
            buildCacheReclaimed: 0,
            containersReclaimed: 0,
            trimmedBytes: 0,
            hostDelta: report.hostDelta,
            source: .largeFiles,
            cachesReclaimed: report.hostDelta
        )
        do {
            try HistoryStore().append(entry)
        } catch {
            FileHandle.standardError.write(Data("warning: failed to record history: \(error)\n".utf8))
        }

        if notify {
            notifyUser(message: "Moved \(formatBytes(report.hostDelta)) of large files to Trash")
        }
    }

    /// Resolves `rawPaths` (from `--only` and/or positional `paths`) against `scan.items`.
    /// Every raw path is canonicalized the same way `LargeItemScanner` derives `LargeItem.id`
    /// (`~`-expand → `resolvingSymlinksInPath().standardizedFileURL`) and looked up by that
    /// canonical id — never trusted as a bare typed path. Any raw path that doesn't match a
    /// scanned item, or whose matched item is protected (`!isSelectable`), rejects the WHOLE
    /// request: nothing is trashed unless every selected path is a real, selectable, just-
    /// scanned item.
    private func resolveSelection(rawPaths: [String], scan: LargeScanResult) throws -> [LargeItem] {
        var itemsByCanonicalPath: [String: LargeItem] = [:]
        for item in scan.items {
            itemsByCanonicalPath[item.id] = item
        }

        var matched: [LargeItem] = []
        var rejected: [String] = []
        for raw in rawPaths {
            let canonical = canonicalPath(raw)
            if let item = itemsByCanonicalPath[canonical], item.isSelectable {
                matched.append(item)
            } else {
                rejected.append(raw)
            }
        }

        guard rejected.isEmpty else {
            throw CLIError(message: """
            Refusing to trash — nothing has been moved. The following path(s) are not in the \
            scanned large-items list, or are protected:
            \(rejected.map { "  " + $0 }.joined(separator: "\n"))
            Only paths shown by `reclaim-cli largefiles` (and not marked 🔒 protected) can be trashed.
            """)
        }

        return matched
    }

    /// `~`-expands and canonicalizes a user-supplied path the same way `LargeItemScanner`
    /// derives each `LargeItem.id`, so a raw CLI argument can be looked up against the scan by
    /// exact key.
    private func canonicalPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Renders an absolute path under `$HOME` as `~/...` for display; paths outside home (there
    /// shouldn't be any, since the scanner never leaves `$HOME`) print unchanged.
    private func homeRelative(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
