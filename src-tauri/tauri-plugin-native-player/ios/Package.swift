// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "tauri-plugin-native-player",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "tauri-plugin-native-player",
            type: .static,
            targets: ["tauri-plugin-native-player"])
    ],
    dependencies: [
        .package(name: "Tauri", path: "../.tauri/tauri-api"),
        .package(url: "https://github.com/tylerjonesio/vlckit-spm", .upToNextMajor(from: "3.5.1")),
    ],
    targets: [
        .target(
            name: "tauri-plugin-native-player",
            dependencies: [
                .byName(name: "Tauri"),
                .product(name: "VLCKitSPM", package: "vlckit-spm"),
            ],
            path: "Sources")
    ]
)
