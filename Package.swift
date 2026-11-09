// swift-tools-version: 6.2

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "SceneItCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SceneItCore", targets: ["SceneItCore"]),
        // Helpers both test targets share; only test targets may depend on it.
        .library(name: "SceneItTestSupport", targets: ["SceneItTestSupport"]),
    ],
    targets: [
        .target(
            name: "SceneItCore",
            swiftSettings: strictSettings
        ),
        .target(
            name: "SceneItTestSupport",
            dependencies: ["SceneItCore"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SceneItCoreTests",
            dependencies: ["SceneItCore", "SceneItTestSupport"],
            path: "Tests",
            sources: ["SceneItCoreTests"],
            resources: [.copy("Corpus")],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
