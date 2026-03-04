// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TouchBro",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "TouchBro",
            dependencies: [],
            path: "Sources",
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
                    "-framework", "MultitouchSupport"
                ])
            ]
        ),
    ]
)
