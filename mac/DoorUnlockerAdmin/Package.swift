// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DoorUnlockerAdmin",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DoorUnlockerCore", targets: ["DoorUnlockerCore"]),
        .executable(name: "DoorUnlockerAdmin", targets: ["DoorUnlockerAdmin"]),
        .executable(name: "door-unlocker", targets: ["DoorUnlockerCLI"])
    ],
    targets: [
        .target(name: "DoorUnlockerCore"),
        .executableTarget(name: "DoorUnlockerAdmin", dependencies: ["DoorUnlockerCore"]),
        .executableTarget(name: "DoorUnlockerCLI", dependencies: ["DoorUnlockerCore"])
    ]
)
