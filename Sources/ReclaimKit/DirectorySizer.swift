import Foundation

/// Computes the on-disk size of a directory tree the same way the numbers `DiskProbe` reports
/// line up: summing each regular file's **allocated** size (block-rounded), not its logical
/// byte length. Chosen over shelling out to `du` — no GUI `PATH` problem, deterministic, and
/// testable with plain temp-directory fixtures.
///
/// Symbolic links are skipped entirely — not followed, not counted — so a cache directory can
/// never cause traversal outside its own root or double-count a target reachable another way.
public enum DirectorySizer {
    public static func size(of url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }

        let resourceKeys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        let keySet = Set(resourceKeys)
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keySet) else { continue }

            // Never follow a symlink: don't descend into it and don't count it.
            if values.isSymbolicLink == true {
                continue
            }
            guard values.isRegularFile == true else { continue }

            let bytes = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
            total += Int64(bytes)
        }
        return total
    }
}
