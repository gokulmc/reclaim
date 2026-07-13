// swift-tools-version:5.9
import PackageDescription

// M1-M4: ReclaimApp is the SwiftUI menu bar shell (MenuBarExtra + detail panel). It depends
// only on ReclaimKit — no UI logic lives in the library. See docs/SPEC.md and
// docs/IMPLEMENTATION.md ("App (M1-M4)").
let package = Package(
    name: "Reclaim",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ReclaimKit", targets: ["ReclaimKit"]),
        .executable(name: "reclaim-cli", targets: ["reclaim-cli"]),
        .executable(name: "ReclaimApp", targets: ["ReclaimApp"])
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
        .executableTarget(
            name: "ReclaimApp",
            dependencies: [
                "ReclaimKit"
            ]
        ),
        .testTarget(
            name: "ReclaimKitTests",
            dependencies: ["ReclaimKit"]
        )
    ]
)
