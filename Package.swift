// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StickiesPlus",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "StickiesPlusKit",
            path: "Sources/StickiesPlusKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "StickiesPlus",
            dependencies: ["StickiesPlusKit"],
            path: "Sources/StickiesPlus",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StickiesPlusTests",
            dependencies: ["StickiesPlusKit"],
            path: "Tests/StickiesPlusTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
