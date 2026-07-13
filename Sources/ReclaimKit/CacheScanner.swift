import Foundation

/// One scanned cache location — a materialized `CacheDefinition` (or, for `.perAppChildren`,
/// one materialized child) with its existing on-disk paths and measured size. Producing a
/// `ScannedCache` is entirely read-only: it only measures bytes with `DirectorySizer`, never
/// deletes anything, and is safe to call repeatedly (e.g. on a poll timer).
public struct ScannedCache: Identifiable, Equatable {
    public let id: String
    public let definitionID: String
    public let displayName: String
    public let existingPaths: [URL]
    public let sizeBytes: Int64
    public let regenerates: Bool

    public init(
        id: String,
        definitionID: String,
        displayName: String,
        existingPaths: [URL],
        sizeBytes: Int64,
        regenerates: Bool
    ) {
        self.id = id
        self.definitionID = definitionID
        self.displayName = displayName
        self.existingPaths = existingPaths
        self.sizeBytes = sizeBytes
        self.regenerates = regenerates
    }
}

/// Scans the dev-tool cache catalog against a real (or injected) `home` directory. Every
/// method here is read-only and side-effect free.
public struct CacheScanner {
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    /// Scans every catalog entry, expanding `.singleDirectory` definitions into at most one
    /// `ScannedCache` each (skipped entirely if none of their paths exist) and
    /// `.perAppChildren` definitions into one `ScannedCache` per immediate subdirectory,
    /// sorted by size descending.
    public func scan(_ catalog: [CacheDefinition]) -> [ScannedCache] {
        catalog.flatMap { definition -> [ScannedCache] in
            switch definition.expansion {
            case .singleDirectory:
                return scanSingleDirectory(definition)
            case .perAppChildren:
                return scanPerAppChildren(definition)
            }
        }
    }

    /// Projects every scanned cache into the shared `ReclaimableItem` shape the Docker
    /// breakdown also produces. Caches are always selectable and never protected — the actual
    /// safety gate (`CacheSafetyGuard`) arrives in a later milestone alongside deletion.
    public func reclaimableItems(_ catalog: [CacheDefinition]) -> [ReclaimableItem] {
        scan(catalog).map { scanned in
            ReclaimableItem(
                id: scanned.id,
                displayName: scanned.displayName,
                detail: scanned.existingPaths.map(\.path).joined(separator: ", "),
                sizeBytes: scanned.sizeBytes,
                category: .cache,
                isSelectable: true,
                isProtected: false
            )
        }
    }

    private func scanSingleDirectory(_ definition: CacheDefinition) -> [ScannedCache] {
        let existingPaths = definition.relativePaths
            .map(resolve)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingPaths.isEmpty else { return [] }

        let sizeBytes = existingPaths.reduce(Int64(0)) { $0 + DirectorySizer.size(of: $1) }
        return [
            ScannedCache(
                id: definition.id,
                definitionID: definition.id,
                displayName: definition.displayName,
                existingPaths: existingPaths,
                sizeBytes: sizeBytes,
                regenerates: definition.regenerates
            )
        ]
    }

    private func scanPerAppChildren(_ definition: CacheDefinition) -> [ScannedCache] {
        guard let relativePath = definition.relativePaths.first else { return [] }
        let root = resolve(relativePath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        let childKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: childKeys,
            options: []
        )) ?? []

        let scanned: [ScannedCache] = children.compactMap { child in
            guard let values = try? child.resourceValues(forKeys: Set(childKeys)),
                  values.isSymbolicLink != true,
                  values.isDirectory == true else {
                return nil
            }
            let name = child.lastPathComponent
            return ScannedCache(
                id: "\(definition.id)/\(name)",
                definitionID: definition.id,
                displayName: name,
                existingPaths: [child],
                sizeBytes: DirectorySizer.size(of: child),
                regenerates: definition.regenerates
            )
        }

        return scanned.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func resolve(_ relativePath: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(relativePath, isDirectory: true)
    }
}
