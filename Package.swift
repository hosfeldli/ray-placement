// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
]
let appDependencies: [Target.Dependency] = [
    "RayPlacementCore",
    "RayPlacementWriting",
    .product(name: "SwiftTerm", package: "SwiftTerm"),
    .product(name: "Sparkle", package: "Sparkle")
]

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
    dependencies: packageDependencies,
    targets: [
        .target(name: "RayPlacementCore"),
        .target(name: "RayPlacementWriting"),
        .executableTarget(
            name: "RayPlacement",
            dependencies: appDependencies
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
