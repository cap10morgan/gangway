// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gangway",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GangwayKit", targets: ["GangwayKit"]),
        .library(name: "GangwayInput", targets: ["GangwayInput"]),
    ],
    dependencies: [
        // The updater. Chosen over a hand-rolled check because the hard parts of
        // updating are the ones that are easy to get subtly wrong: verifying the
        // signature of what was downloaded, and replacing a running app safely.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "GangwayKit"),
        .target(name: "GangwayInput", dependencies: ["GangwayKit"]),
        .executableTarget(name: "gangwayctl", dependencies: ["GangwayKit", "GangwayInput"]),
        .executableTarget(name: "GangwayApp",
                          dependencies: ["GangwayKit", "GangwayInput",
                                         .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "GangwayKitTests", dependencies: ["GangwayKit"]),
        .testTarget(name: "GangwayInputTests", dependencies: ["GangwayInput", "GangwayKit"]),
    ]
)
