// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Fritz",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Bonsplit", targets: ["Bonsplit"]),
        .library(name: "FritzUI", targets: ["FritzUI"]),
        .library(name: "FritzState", targets: ["FritzState"]),
        .library(name: "Fritz", targets: ["Fritz"]),
        .library(name: "FritzUpdates", targets: ["FritzUpdates"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(name: "Bonsplit", path: "Packages/Bonsplit/Sources/Bonsplit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BonsplitTests", dependencies: ["Bonsplit"], path: "Packages/Bonsplit/Tests/BonsplitTests", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "FritzUI", dependencies: ["Fritz", "Bonsplit"]),
        .testTarget(name: "FritzUISnapshotTests", dependencies: [
            "FritzUI",
            .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
        ], path: "tests/FritzUISnapshotTests", exclude: ["__Snapshots__"]),
        .testTarget(name: "FritzUITests", dependencies: ["FritzUI"], path: "tests/FritzUITests"),
        .target(name: "FritzState", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "FritzStateTests", dependencies: ["FritzState"], path: "tests/FritzStateTests"),
        .target(name: "Fritz", resources: [.copy("LocalModels.json"), .copy("DecisionModels.json"), .copy("OpenAIModels.json")]),
        .target(name: "FritzUpdates", dependencies: [
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .testTarget(name: "FritzTests", dependencies: ["Fritz", "FritzUpdates"], path: "tests/FritzTests"),
    ]
)
