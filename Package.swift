// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Station",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StationKit", targets: ["StationKit"]),
    ],
    targets: [
        .target(name: "StationKit"),
        .testTarget(name: "StationKitTests", dependencies: ["StationKit"]),
    ]
)
