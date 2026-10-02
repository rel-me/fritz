// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "NativeMarkup",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NativeMarkupCore", targets: ["NativeMarkupCore"]),
        .library(name: "NativeMarkupUI", targets: ["NativeMarkupUI"]),
        .library(name: "NativeMarkupDevelopment", targets: ["NativeMarkupDevelopment"]),
    ],
    targets: [
        .target(name: "NativeMarkupCore"),
        .target(name: "NativeMarkupUI", dependencies: ["NativeMarkupCore"]),
        .target(name: "NativeMarkupDevelopment"),
        .testTarget(name: "NativeMarkupCoreTests", dependencies: ["NativeMarkupCore"]),
        .testTarget(name: "NativeMarkupUITests", dependencies: ["NativeMarkupUI"]),
        .testTarget(name: "NativeMarkupDevelopmentTests", dependencies: ["NativeMarkupDevelopment"]),
    ]
)
