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

// QA transport and stdio MCP adapter are intentionally absent from the default
// manifest. A QA package must opt in before these targets and the LIMA_QA app
// compilation flag exist.
let buildQAMCP = ProcessInfo.processInfo.environment["LIMA_BUILD_QA_MCP"] == "1"
var qaAppDependencies = appDependencies
if buildQAMCP { qaAppDependencies.append("LimaQAProtocol") }
let qaProducts: [Product] = buildQAMCP
    ? [.executable(name: "LimaQAMCPServer", targets: ["LimaQAMCPServer"])]
    : []
let qaTargets: [Target] = buildQAMCP
    ? [
        .target(name: "LimaQAProtocol"),
        .executableTarget(name: "LimaQAMCPServer", dependencies: ["LimaQAProtocol"]),
        .testTarget(name: "LimaQAProtocolTests", dependencies: ["LimaQAProtocol"])
    ]
    : []
let qaAppSettings: [SwiftSetting] = buildQAMCP ? [.define("LIMA_QA")] : []

let package = Package(
    name: "RayPlacement",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RayPlacement", targets: ["RayPlacement"]),
        .executable(name: "LimaBrowserBridgeHost", targets: ["LimaBrowserBridgeHost"]),
        .library(name: "RayPlacementCore", targets: ["RayPlacementCore"]),
        .library(name: "RayPlacementWriting", targets: ["RayPlacementWriting"])
    ] + qaProducts,
    dependencies: packageDependencies,
    targets: [
        .target(name: "RayPlacementCore", resources: [.process("Fixtures")]),
        .target(name: "RayPlacementWriting"),
        .executableTarget(
            name: "LimaBrowserBridgeHost",
            dependencies: ["RayPlacementCore"]
        ),
        .executableTarget(
            name: "RayPlacement",
            dependencies: qaAppDependencies,
            swiftSettings: qaAppSettings
        ),
        .testTarget(
            name: "RayPlacementCoreTests",
            dependencies: ["RayPlacementCore"]
        ),
        .testTarget(
            name: "RayPlacementWritingTests",
            dependencies: ["RayPlacementWriting"]
        ),
        .testTarget(
            name: "RayPlacementTests",
            dependencies: ["RayPlacement"]
        )
    ] + qaTargets,
    swiftLanguageModes: [.v5]
)
