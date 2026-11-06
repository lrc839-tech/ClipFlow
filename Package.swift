// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipFlow",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipFlowCore", targets: ["ClipFlowCore"]),
        .executable(name: "ClipFlowProbe", targets: ["ClipFlowProbe"]),
        .executable(name: "ClipFlowTarget", targets: ["ClipFlowTarget"]),
        .executable(name: "ClipFlowApp", targets: ["ClipFlowApp"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: nil, providers: []),
        .target(name: "ClipFlowCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "ClipFlowProbe", dependencies: ["ClipFlowCore"]),
        .executableTarget(name: "ClipFlowTarget"),
        .executableTarget(name: "ClipFlowApp", dependencies: ["ClipFlowCore"]),
        .testTarget(name: "ClipFlowCoreTests", dependencies: ["ClipFlowCore"])
    ],
    swiftLanguageModes: [.v5]
)
