// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Harbor",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "Harbor", targets: ["Harbor"]),
        .executable(name: "harbor-cli", targets: ["harbor-cli"]),
        .library(name: "HarborKit", targets: ["HarborKit"]),
    ],
    targets: [
        .target(name: "HarborKit"),
        .executableTarget(name: "Harbor", dependencies: ["HarborKit"]),
        .executableTarget(name: "harbor-cli", dependencies: ["HarborKit"]),
        .testTarget(name: "HarborKitTests", dependencies: ["HarborKit"]),
    ]
)
