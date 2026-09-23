// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Fritz",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FritzState", targets: ["FritzState"]),
        .library(name: "Fritz", targets: ["Fritz"]),
        .library(name: "FritzUpdates", targets: ["FritzUpdates"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(name: "FritzState", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "FritzStateTests", dependencies: ["FritzState"], path: "tests/FritzStateTests"),
        .target(name: "Fritz", resources: [.copy("LocalModels.json")]),
        .target(name: "FritzUpdates", dependencies: [
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .testTarget(name: "FritzTests", dependencies: ["Fritz", "FritzUpdates"], path: "tests/FritzTests"),
    ]
)
