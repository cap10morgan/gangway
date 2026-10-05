// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gangway",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GangwayKit", targets: ["GangwayKit"]),
        .library(name: "GangwayInput", targets: ["GangwayInput"]),
    ],
    targets: [
        .target(name: "GangwayKit"),
        .target(name: "GangwayInput", dependencies: ["GangwayKit"]),
        .executableTarget(name: "gangwayctl", dependencies: ["GangwayKit", "GangwayInput"]),
        .executableTarget(name: "GangwayApp", dependencies: ["GangwayKit", "GangwayInput"]),
        .testTarget(name: "GangwayKitTests", dependencies: ["GangwayKit"]),
        .testTarget(name: "GangwayInputTests", dependencies: ["GangwayInput", "GangwayKit"]),
    ]
)
