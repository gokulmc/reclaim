import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A point-in-time host disk reading. Pure value type so it's trivial to compare
/// before/after snapshots and to construct by hand in tests.
public struct DiskStat: Equatable {
    public let freeBytes: Int64
    public let totalBytes: Int64

    public init(freeBytes: Int64, totalBytes: Int64) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
    }
}

public enum DiskProbeError: Error, Equatable, CustomStringConvertible {
    case statfsFailed(String, Int32)

    public var description: String {
        switch self {
        case .statfsFailed(let path, let errnoValue):
            return "statfs(\(path)) failed (errno \(errnoValue))"
        }
    }
}

/// Reads host free/total disk space via `statfs(2)`. This is the "honest number" the whole
/// app is built around (SPEC.md §2.5) — Docker's own `RECLAIMABLE` estimate is not trusted;
/// only a real before/after `statfs` delta is reported as the headline result.
///
/// The `path` parameter makes this injectable for tests (point it at a temp directory instead
/// of `/`) without needing to fake the syscall itself.
public enum DiskProbe {
    public static func stat(path: String = "/") throws -> DiskStat {
        var buffer = statfs()
        let result = statfs(path, &buffer)
        guard result == 0 else {
            throw DiskProbeError.statfsFailed(path, errno)
        }
        let free = Int64(buffer.f_bavail) * Int64(buffer.f_bsize)
        let total = Int64(buffer.f_blocks) * Int64(buffer.f_bsize)
        return DiskStat(freeBytes: free, totalBytes: total)
    }
}
