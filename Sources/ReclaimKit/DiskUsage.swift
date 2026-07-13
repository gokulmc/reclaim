import Foundation

/// One entry from the `Images` array of `GET /system/df`.
public struct ImageSummary: Decodable, Equatable {
    public let id: String
    /// Number of containers referencing this image. `0` means unused/reclaimable.
    public let containers: Int64
    public let size: Int64
    public let sharedSize: Int64
    public let repoTags: [String]

    public var isUnused: Bool { containers == 0 }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case containers = "Containers"
        case size = "Size"
        case sharedSize = "SharedSize"
        case repoTags = "RepoTags"
    }

    public init(id: String, containers: Int64, size: Int64, sharedSize: Int64, repoTags: [String]) {
        self.id = id
        self.containers = containers
        self.size = size
        self.sharedSize = sharedSize
        self.repoTags = repoTags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        containers = try c.decodeIfPresent(Int64.self, forKey: .containers) ?? -1
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        sharedSize = try c.decodeIfPresent(Int64.self, forKey: .sharedSize) ?? 0
        repoTags = try c.decodeIfPresent([String].self, forKey: .repoTags) ?? []
    }
}

/// One entry from the `Containers` array of `GET /system/df` (a slimmer shape than the full
/// `/containers/json` summary — just enough to total up stopped-container disk usage).
public struct ContainerDFSummary: Decodable, Equatable {
    public let id: String
    public let state: String
    /// Writable-layer size. Docker omits/nulls this for some containers (observed on live
    /// daemons) — always tolerate a missing value as zero.
    public let sizeRw: Int64?
    public let sizeRootFs: Int64?

    public var isStopped: Bool { state.lowercased() != "running" }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case state = "State"
        case sizeRw = "SizeRw"
        case sizeRootFs = "SizeRootFs"
    }

    public init(id: String, state: String, sizeRw: Int64?, sizeRootFs: Int64?) {
        self.id = id
        self.state = state
        self.sizeRw = sizeRw
        self.sizeRootFs = sizeRootFs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        sizeRw = try c.decodeIfPresent(Int64.self, forKey: .sizeRw)
        sizeRootFs = try c.decodeIfPresent(Int64.self, forKey: .sizeRootFs)
    }
}

/// One entry from the `BuildCache` array of `GET /system/df`.
public struct BuildCacheRecord: Decodable, Equatable {
    public let id: String
    public let type: String
    public let inUse: Bool
    public let shared: Bool
    public let size: Int64

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case type = "Type"
        case inUse = "InUse"
        case shared = "Shared"
        case size = "Size"
    }

    public init(id: String, type: String, inUse: Bool, shared: Bool, size: Int64) {
        self.id = id
        self.type = type
        self.inUse = inUse
        self.shared = shared
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        inUse = try c.decodeIfPresent(Bool.self, forKey: .inUse) ?? false
        shared = try c.decodeIfPresent(Bool.self, forKey: .shared) ?? false
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
    }
}

/// A Docker volume (`GET /volumes`, and the `Volumes` array embedded in `GET /system/df`).
/// **Read-only everywhere in this app** — see `SafetyGuard` and SPEC.md §2.
public struct Volume: Decodable, Equatable {
    public let name: String
    public let driver: String
    public let mountpoint: String
    public let createdAt: String?
    public let labels: [String: String]?
    public let scope: String?
    /// From `UsageData.Size`. `nil` if Docker didn't compute usage data at all; Docker itself
    /// may also report `-1` to mean "not computed" — callers should treat non-positive values
    /// as "unknown", not as zero bytes.
    public let usageSize: Int64?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case mountpoint = "Mountpoint"
        case createdAt = "CreatedAt"
        case labels = "Labels"
        case scope = "Scope"
        case usageData = "UsageData"
    }

    enum UsageDataKeys: String, CodingKey {
        case size = "Size"
    }

    public init(
        name: String,
        driver: String,
        mountpoint: String,
        createdAt: String?,
        labels: [String: String]?,
        scope: String?,
        usageSize: Int64?
    ) {
        self.name = name
        self.driver = driver
        self.mountpoint = mountpoint
        self.createdAt = createdAt
        self.labels = labels
        self.scope = scope
        self.usageSize = usageSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? "local"
        mountpoint = try c.decodeIfPresent(String.self, forKey: .mountpoint) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)

        if let usageContainer = try? c.nestedContainer(keyedBy: UsageDataKeys.self, forKey: .usageData) {
            usageSize = try usageContainer.decodeIfPresent(Int64.self, forKey: .size)
        } else {
            usageSize = nil
        }
    }
}

/// One entry from `GET /containers/json`.
public struct ContainerSummary: Decodable, Equatable {
    public let id: String
    public let names: [String]
    public let image: String
    public let state: String
    public let status: String
    public let created: Int64

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case image = "Image"
        case state = "State"
        case status = "Status"
        case created = "Created"
    }

    public init(id: String, names: [String], image: String, state: String, status: String, created: Int64) {
        self.id = id
        self.names = names
        self.image = image
        self.state = state
        self.status = status
        self.created = created
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        created = try c.decodeIfPresent(Int64.self, forKey: .created) ?? 0
    }
}

/// The parsed result of `GET /system/df`. Every array may be `null` on the wire — tolerate
/// that by decoding to `[]`.
public struct DiskUsage: Decodable, Equatable {
    public let layersSize: Int64
    public let images: [ImageSummary]
    public let containers: [ContainerDFSummary]
    public let volumes: [Volume]
    public let buildCache: [BuildCacheRecord]

    enum CodingKeys: String, CodingKey {
        case layersSize = "LayersSize"
        case images = "Images"
        case containers = "Containers"
        case volumes = "Volumes"
        case buildCache = "BuildCache"
    }

    public init(
        layersSize: Int64,
        images: [ImageSummary],
        containers: [ContainerDFSummary],
        volumes: [Volume],
        buildCache: [BuildCacheRecord]
    ) {
        self.layersSize = layersSize
        self.images = images
        self.containers = containers
        self.volumes = volumes
        self.buildCache = buildCache
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layersSize = try c.decodeIfPresent(Int64.self, forKey: .layersSize) ?? 0
        images = try c.decodeIfPresent([ImageSummary].self, forKey: .images) ?? []
        containers = try c.decodeIfPresent([ContainerDFSummary].self, forKey: .containers) ?? []
        volumes = try c.decodeIfPresent([Volume].self, forKey: .volumes) ?? []
        buildCache = try c.decodeIfPresent([BuildCacheRecord].self, forKey: .buildCache) ?? []
    }
}

// MARK: - Derived breakdown (SPEC §7: surface build cache first — it's usually the big one)

extension DiskUsage {
    public var imagesTotalSize: Int64 { images.reduce(0) { $0 + $1.size } }
    public var imagesReclaimableSize: Int64 { images.filter(\.isUnused).reduce(0) { $0 + $1.size } }
    public var imagesReclaimableCount: Int { images.filter(\.isUnused).count }

    public var buildCacheTotalSize: Int64 { buildCache.reduce(0) { $0 + $1.size } }
    public var buildCacheReclaimableSize: Int64 { buildCache.filter { !$0.inUse }.reduce(0) { $0 + $1.size } }
    public var buildCacheReclaimableCount: Int { buildCache.filter { !$0.inUse }.count }

    public var stoppedContainersCount: Int { containers.filter(\.isStopped).count }
    public var stoppedContainersSize: Int64 { containers.filter(\.isStopped).reduce(0) { $0 + ($1.sizeRw ?? 0) } }

    public var volumesCount: Int { volumes.count }
    /// Sum of known volume usage sizes. Volumes with an unknown/uncomputed size (`nil` or a
    /// negative `UsageData.Size`) are excluded from the total rather than silently counted as
    /// zero or negative bytes.
    public var volumesTotalSize: Int64 {
        volumes.compactMap { $0.usageSize }.filter { $0 >= 0 }.reduce(0, +)
    }
}

/// Result of a prune call (`/images/prune`, `/build/prune`, `/containers/prune`). Docker's
/// three prune endpoints use different field names for "what got deleted"
/// (`ImagesDeleted`/`ContainersDeleted`/`CachesDeleted`) but all share `SpaceReclaimed`.
public struct PruneResult: Equatable {
    public let deleted: [String]
    public let spaceReclaimed: Int64

    public init(deleted: [String], spaceReclaimed: Int64) {
        self.deleted = deleted
        self.spaceReclaimed = spaceReclaimed
    }
}

/// Result of `DELETE /images/{id}`. Unlike the prune endpoints, Docker's wire shape here is a
/// **JSON array** of per-layer actions — `[{"Untagged": "repo:tag"}, {"Deleted": "sha256:..."}]`
/// — not a single object with a `SpaceReclaimed` field, so it needs its own decode path (see
/// `DockerClient.decodeImageDeleteResult`) rather than reusing `decodePruneResult`.
public struct ImageDeleteResult: Equatable {
    public let untagged: [String]
    public let deleted: [String]

    public init(untagged: [String], deleted: [String]) {
        self.untagged = untagged
        self.deleted = deleted
    }
}
