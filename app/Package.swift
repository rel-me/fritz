// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "FritzApp",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "FritzApp", targets: ["FritzApp"])],
    dependencies: [
        .package(name: "Fritz", path: ".."),
        .package(path: "../Packages/NativeMarkup"),
        .package(url: "https://github.com/gonzalezreal/textual", exact: "0.5.0"),
    ],
    targets: [
        .executableTarget(name: "FritzApp", dependencies: [
            .product(name: "Bonsplit", package: "Fritz"),
            .product(name: "FritzState", package: "Fritz"),
            .product(name: "Fritz", package: "Fritz"),
            .product(name: "FritzUI", package: "Fritz"),
            .product(name: "FritzUpdates", package: "Fritz"),
            .product(name: "Textual", package: "textual"),
            .product(name: "NativeMarkupUI", package: "NativeMarkup"),
            .product(name: "NativeMarkupDevelopment", package: "NativeMarkup"),
        ], path: "Sources/Fritz"),
        .testTarget(name: "FritzTests", dependencies: ["FritzApp"]),
    ]
)
