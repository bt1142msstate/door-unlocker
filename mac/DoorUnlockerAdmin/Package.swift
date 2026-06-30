// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DoorUnlockerAdmin",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DoorUnlockerAdmin", targets: ["DoorUnlockerAdmin"])
    ],
    targets: [
        .executableTarget(name: "DoorUnlockerAdmin")
    ]
)
