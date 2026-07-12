// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NordicDFU",
    platforms: [
        .macOS(.v10_14),
        .iOS(.v12),
        .watchOS(.v4),
        .tvOS(.v12)
    ],
    products: [
        .library(name: "NordicDFU", targets: ["NordicDFU"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation", exact: "0.9.19")
    ],
    targets: [
        .target(
            name: "NordicDFU",
            dependencies: ["ZIPFoundation"],
            path: "Library",
            resources: [.process("Assets/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "NordicDFUTests",
            dependencies: ["NordicDFU"],
            path: "Tests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
