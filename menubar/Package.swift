// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Router",
    platforms: [
        .macOS(.v15),
    ],
    targets: [
        .executableTarget(
            name: "Router",
            path: "Sources/Router")
    ]
)
