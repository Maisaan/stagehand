// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "stagehand",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Stagehand", targets: ["Stagehand"])],
    targets: [
        .target(name: "StagehandCore"),
        .target(name: "StagehandPlatform", dependencies: ["StagehandCore"]),
        .executableTarget(
            name: "Stagehand",
            dependencies: ["StagehandCore", "StagehandPlatform"],
            resources: [.copy("Resources/Phosphor")]
        ),
        .testTarget(name: "StagehandCoreTests", dependencies: ["StagehandCore"]),
        .testTarget(name: "StagehandPlatformTests", dependencies: ["StagehandPlatform", "StagehandCore"]),
        .testTarget(name: "StagehandTests", dependencies: ["Stagehand"])
    ]
)
