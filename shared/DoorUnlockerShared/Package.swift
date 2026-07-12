// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DoorUnlockerShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "DoorUnlockerShared", targets: ["DoorUnlockerShared"]),
        .library(name: "DoorUnlockerDFU", targets: ["DoorUnlockerDFU"])
    ],
    dependencies: [
        .package(path: "../../vendor/IOS-DFU-Library")
    ],
    targets: [
        .target(name: "DoorUnlockerShared"),
        .target(
            name: "DoorUnlockerDFU",
            dependencies: [
                "DoorUnlockerShared",
                .product(name: "NordicDFU", package: "IOS-DFU-Library")
            ]
        ),
        .testTarget(name: "DoorUnlockerSharedTests", dependencies: ["DoorUnlockerShared"])
    ]
)
