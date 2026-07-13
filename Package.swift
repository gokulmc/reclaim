// swift-tools-version:5.9
import PackageDescription

// Note: an additional `ReclaimApp` (SwiftUI menu bar) executable target is planned for a
// later milestone (M1+) but is intentionally not added yet — M0 is ReclaimKit + reclaim-cli
// only. See docs/SPEC.md and docs/IMPLEMENTATION.md.
let package = Package(
    name: "Reclaim",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ReclaimKit", targets: ["ReclaimKit"]),
        .executable(name: "reclaim-cli", targets: ["reclaim-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "ReclaimKit",
            dependencies: []
        ),
        .executableTarget(
            name: "reclaim-cli",
            dependencies: [
                "ReclaimKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "ReclaimKitTests",
            dependencies: ["ReclaimKit"]
        )
    ]
)
