import Foundation

/// A catalog entry describing one dev-tool cache location. `relativePaths` are always
/// relative to an injectable `home` (mirrors `HistoryStore(fileURL:)`) — a definition can
/// never point outside `$HOME`, and they are joined to `home` only at scan time by
/// `CacheScanner`, never stored as absolute paths here.
public struct CacheDefinition: Identifiable, Equatable {
    /// How a catalog entry expands into one or more scannable/selectable items.
    public enum Expansion: Equatable {
        /// The whole `relativePaths` set is sized (and, in a later milestone, deleted) as one
        /// unit — e.g. Xcode DerivedData.
        case singleDirectory
        /// Each immediate child of the (single) relative path is its own item, sized
        /// individually — used for `~/Library/Caches`, which is app-wise, never one blob.
        case perAppChildren
    }

    public let id: String
    public let displayName: String
    public let description: String
    public let relativePaths: [String]
    public let regenerates: Bool
    public let expansion: Expansion

    public init(
        id: String,
        displayName: String,
        description: String,
        relativePaths: [String],
        regenerates: Bool,
        expansion: Expansion
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.relativePaths = relativePaths
        self.regenerates = regenerates
        self.expansion = expansion
    }
}

/// The built-in list of dev-tool caches Reclaim knows how to find. `home` is accepted (and
/// defaults to the real home directory) purely so callers/tests can be explicit about which
/// home the catalog is being described for; the definitions themselves only ever hold
/// relative paths, joined to `home` later by `CacheScanner`.
public enum CacheCatalog {
    public static func `default`(home: String = NSHomeDirectory()) -> [CacheDefinition] {
        _ = home
        return [
            CacheDefinition(
                id: "xcode-derived-data",
                displayName: "Xcode DerivedData",
                description: "Xcode's build products and indexes — fully rebuilt on next build.",
                relativePaths: ["Library/Developer/Xcode/DerivedData"],
                regenerates: true,
                expansion: .singleDirectory
            ),
            CacheDefinition(
                id: "homebrew",
                displayName: "Homebrew cache",
                description: "Downloaded bottles and formulae Homebrew can re-fetch.",
                relativePaths: ["Library/Caches/Homebrew"],
                regenerates: true,
                expansion: .singleDirectory
            ),
            CacheDefinition(
                id: "npm",
                displayName: "npm cache",
                description: "Downloaded packages npm can re-fetch.",
                relativePaths: [".npm"],
                regenerates: true,
                expansion: .singleDirectory
            ),
            CacheDefinition(
                id: "pnpm",
                displayName: "pnpm store",
                description: "pnpm's content-addressable package store, re-populated on install.",
                relativePaths: ["Library/pnpm/store", ".local/share/pnpm/store"],
                regenerates: true,
                expansion: .singleDirectory
            ),
            CacheDefinition(
                id: "yarn",
                displayName: "Yarn cache",
                description: "Downloaded packages Yarn can re-fetch.",
                relativePaths: ["Library/Caches/Yarn", ".cache/yarn"],
                regenerates: true,
                expansion: .singleDirectory
            ),
            CacheDefinition(
                id: "pip",
                displayName: "pip cache",
                description: "Downloaded Python wheels and sdists pip can re-fetch.",
                relativePaths: ["Library/Caches/pip"],
                regenerates: true,
                expansion: .singleDirectory
            ),
            CacheDefinition(
                id: "gradle",
                displayName: "Gradle caches",
                description: "Downloaded dependencies and build caches Gradle can regenerate.",
                relativePaths: [".gradle/caches"],
                regenerates: true,
                expansion: .singleDirectory
            ),
            CacheDefinition(
                id: "cocoapods",
                displayName: "CocoaPods cache",
                description: "Downloaded pod specs and sources CocoaPods can re-fetch.",
                relativePaths: ["Library/Caches/CocoaPods"],
                regenerates: true,
                expansion: .singleDirectory
            ),
            CacheDefinition(
                id: "library-caches",
                displayName: "App caches (~/Library/Caches)",
                description: "Per-app caches macOS apps rebuild on demand.",
                relativePaths: ["Library/Caches"],
                regenerates: true,
                expansion: .perAppChildren
            )
        ]
    }
}
