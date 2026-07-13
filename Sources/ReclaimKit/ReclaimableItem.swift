import Foundation

/// A unified, read-only view-model item that both the Docker breakdown and the dev-tool
/// cache catalog project into. The two engines (`Reclaimer`/`DockerClient` and
/// `CacheScanner`) stay separate and independently testable — this struct is only the shared
/// shape consumed by UI/CLI, not a protocol retrofit (see docs/plan: "additive, not a
/// protocol retrofit").
public struct ReclaimableItem: Identifiable, Equatable {
    public enum Category: Equatable {
        case buildCache
        case image
        case container
        case cache
        case protectedData
    }

    public let id: String
    public let displayName: String
    public let detail: String
    public let sizeBytes: Int64
    public let category: Category
    public let isSelectable: Bool
    public let isProtected: Bool

    public init(
        id: String,
        displayName: String,
        detail: String,
        sizeBytes: Int64,
        category: Category,
        isSelectable: Bool,
        isProtected: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.sizeBytes = sizeBytes
        self.category = category
        self.isSelectable = isSelectable
        self.isProtected = isProtected
    }
}
