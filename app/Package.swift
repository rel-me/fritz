// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Fritz",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Fritz", targets: ["Fritz"])],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/textual", exact: "0.5.0")
    ],
    targets: [
        .executableTarget(name: "Fritz", dependencies: [
            .product(name: "Textual", package: "textual")
        ], resources: [.copy("LocalModels.json")]),
        .testTarget(name: "FritzTests", dependencies: ["Fritz"])
    ]
)
