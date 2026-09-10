// swift-tools-version: 6.0

import Foundation
import PackageDescription

let enableSparkleMigration = ProcessInfo.processInfo.environment["LIMA_ENABLE_SPARKLE_MIGRATION"] == "1"
var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0")
]
var appDependencies: [Target.Dependency] = [
    "RayPlacementCore",
    "RayPlacementWriting",
    .product(name: "SwiftTerm", package: "SwiftTerm")
]
if enableSparkleMigration {
    packageDependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.4"))
    appDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
}

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
            dependencies: appDependencies,
            swiftSettings: enableSparkleMigration ? [.define("LIMA_SPARKLE_MIGRATION")] : []
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
