// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RayPlacement",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RayPlacement", targets: ["RayPlacement"]),
        .library(name: "RayPlacementCore", targets: ["RayPlacementCore"]),
        .library(name: "RayPlacementWriting", targets: ["RayPlacementWriting"])
    ],
    targets: [
        .target(name: "RayPlacementCore"),
        .target(name: "RayPlacementWriting"),
        .executableTarget(
            name: "RayPlacement",
            dependencies: ["RayPlacementCore", "RayPlacementWriting"]
        ),
        .testTarget(
            name: "RayPlacementCoreTests",
            dependencies: ["RayPlacementCore"]
        ),
        .testTarget(
            name: "RayPlacementWritingTests",
            dependencies: ["RayPlacementWriting"]
        )
    ],
    swiftLanguageModes: [.v5]
)
