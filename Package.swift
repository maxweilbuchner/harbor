// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Harbor",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Harbor", targets: ["Harbor"]),
        .executable(name: "harbor-cli", targets: ["harbor-cli"]),
        .library(name: "HarborKit", targets: ["HarborKit"]),
    ],
    dependencies: [
        // App updates. Pinned exactly; bump together with SPARKLE_VERSION in scripts/versions.env.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "HarborKit"),
        .executableTarget(name: "Harbor", dependencies: ["HarborKit", .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "harbor-cli", dependencies: ["HarborKit"]),
        .testTarget(name: "HarborKitTests", dependencies: ["HarborKit"],
                    resources: [.copy("Fixtures/app64.exe"), .copy("Fixtures/app32.exe"), .copy("Fixtures/game64.exe"),
                                .copy("Fixtures/d3dapp64.exe")]),
    ]
)
