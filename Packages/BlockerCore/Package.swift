// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BlockerCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BlockerCore", targets: ["BlockerCore"]),
        .executable(name: "obconvert", targets: ["obconvert"]),
    ],
    targets: [
        .target(name: "BlockerCore"),
        .executableTarget(name: "obconvert", dependencies: ["BlockerCore"]),
        .testTarget(name: "BlockerCoreTests", dependencies: ["BlockerCore"]),
    ]
)
