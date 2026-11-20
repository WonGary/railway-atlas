// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RailwayAtlas",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RailwayCore", targets: ["RailwayCore"]),
        .executable(name: "RailwayAtlasCheck", targets: ["RailwayAtlasCheck"]),
        .executable(
            name: "RailwayAtlas",
            targets: ["RailwayAtlas"]
        )
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "RailwayCore", dependencies: ["CSQLite"], resources: [.process("Resources")]),
        .executableTarget(
            name: "RailwayAtlas",
            dependencies: ["RailwayCore"],
            path: "Sources/RailwayAtlas",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "RailwayAtlasCheck",
            dependencies: ["RailwayCore", "CSQLite"],
            path: "Checks"
        )
    ]
)
