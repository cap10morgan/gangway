// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GestureSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GestureSpike", path: "Sources/GestureSpike"),
        .executableTarget(name: "GestureProof", path: "Sources/GestureProof")
    ]
)
