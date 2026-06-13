// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CmuxStripLayout",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CmuxStripLayout",
            targets: ["CmuxStripLayout"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxStripLayout",
            path: "Sources/CmuxStripLayout"
        ),
        .testTarget(
            name: "CmuxStripLayoutTests",
            dependencies: ["CmuxStripLayout"],
            path: "Tests/CmuxStripLayoutTests"
        ),
    ]
)
