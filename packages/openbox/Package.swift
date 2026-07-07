// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenBox",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "OpenBox", targets: ["OpenBox"]),
        .executable(name: "openbox", targets: ["OpenBoxCLI"]),
    ],
    targets: [
        .target(name: "OpenBox"),
        .executableTarget(
            name: "OpenBoxCLI",
            dependencies: ["OpenBox"]
        ),
        .testTarget(
            name: "OpenBoxTests",
            dependencies: ["OpenBox"]
        ),
    ]
)
