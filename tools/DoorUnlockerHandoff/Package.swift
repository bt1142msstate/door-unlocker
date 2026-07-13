// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoorUnlockerHandoff",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "door-unlocker-handoff", targets: ["DoorUnlockerHandoff"]),
    ],
    targets: [
        .executableTarget(name: "DoorUnlockerHandoff"),
    ]
)
