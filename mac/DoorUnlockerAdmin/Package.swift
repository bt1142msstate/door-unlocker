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
    dependencies: [
        .package(path: "../../shared/DoorUnlockerShared"),
        .package(url: "https://github.com/NordicSemiconductor/IOS-DFU-Library", from: "4.16.0")
    ],
    targets: [
        .target(name: "DoorUnlockerCore", dependencies: ["DoorUnlockerShared"]),
        .executableTarget(
            name: "DoorUnlockerAdmin",
            dependencies: [
                "DoorUnlockerCore",
                "DoorUnlockerShared",
                .product(name: "NordicDFU", package: "IOS-DFU-Library")
            ]
        ),
        .executableTarget(name: "DoorUnlockerCLI", dependencies: ["DoorUnlockerCore"]),
        .testTarget(name: "DoorUnlockerCoreTests", dependencies: ["DoorUnlockerCore"])
    ]
)
