// swift-tools-version: 6.2

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "SceneItCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SceneItCore", targets: ["SceneItCore"])
    ],
    targets: [
        .target(
            name: "SceneItCore",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "SceneItCoreTests",
            dependencies: ["SceneItCore"],
            path: "Tests",
            sources: ["SceneItCoreTests"],
            resources: [.copy("Corpus")],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
