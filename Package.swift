// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Station",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StationKit", targets: ["StationKit"]),
        .library(name: "StationInput", targets: ["StationInput"]),
    ],
    targets: [
        .target(name: "StationKit"),
        .target(name: "StationInput", dependencies: ["StationKit"]),
        .executableTarget(name: "stationctl", dependencies: ["StationKit", "StationInput"]),
        .testTarget(name: "StationKitTests", dependencies: ["StationKit"]),
    ]
)
