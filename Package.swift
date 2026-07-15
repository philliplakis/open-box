// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenBox",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "OpenBox", targets: ["OpenBox"]),
        .library(name: "OpenBoxClient", targets: ["OpenBoxClient"]),
        .executable(name: "openbox", targets: ["OpenBoxCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.25.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "OpenBox",
            path: "packages/openbox/Sources/OpenBox"
        ),
        .target(
            name: "OpenBoxClient",
            path: "packages/openbox/Sources/OpenBoxClient"
        ),
        .target(
            name: "OpenBoxServer",
            dependencies: [
                "OpenBox",
                "OpenBoxClient",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdRouter", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ],
            path: "packages/openbox/Sources/OpenBoxServer"
        ),
        .executableTarget(
            name: "OpenBoxCLI",
            dependencies: ["OpenBox", "OpenBoxClient", "OpenBoxServer"],
            path: "packages/openbox/Sources/OpenBoxCLI"
        ),
        .testTarget(
            name: "OpenBoxTests",
            dependencies: [
                "OpenBox",
                "OpenBoxClient",
                "OpenBoxServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HummingbirdWSTesting", package: "hummingbird-websocket"),
            ],
            path: "packages/openbox/Tests/OpenBoxTests"
        ),
    ]
)
