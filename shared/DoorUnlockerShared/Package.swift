// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DoorUnlockerShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "DoorUnlockerShared", targets: ["DoorUnlockerShared"])
    ],
    targets: [
        .target(name: "DoorUnlockerShared"),
        .testTarget(name: "DoorUnlockerSharedTests", dependencies: ["DoorUnlockerShared"])
    ]
)
