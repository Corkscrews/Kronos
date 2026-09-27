// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Kronos",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(name: "Kronos", targets: ["Kronos"]),
    ],
    targets: [
        .target(
            name: "Kronos",
            path: "Sources",
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "KronosTests",
            dependencies: ["Kronos"],
            path: "Tests/KronosTests"
        ),
    ]
)
