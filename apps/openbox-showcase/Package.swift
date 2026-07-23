// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenBoxShowcase",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "OpenBoxShowcase",
            dependencies: [.product(name: "OpenBoxClient", package: "open-box")]
        )
    ]
)
