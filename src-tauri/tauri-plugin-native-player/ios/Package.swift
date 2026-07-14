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
        .package(name: "Tauri", path: "../.tauri/tauri-api")
    ],
    targets: [
        // Vendored mpv client API. The actual libmpv (+ ffmpeg, libplacebo,
        // MoltenVK, …) xcframeworks are linked by the app's Xcode project in CI;
        // the SwiftPM CLI build only needs the header to compile against.
        .target(
            name: "Cmpv",
            path: "Sources/Cmpv",
            publicHeadersPath: "include"),
        .target(
            name: "tauri-plugin-native-player",
            dependencies: [
                .byName(name: "Tauri"),
                "Cmpv",
            ],
            path: "Sources/NativePlayer",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("c++"),
                .linkedLibrary("bz2"),
                .linkedLibrary("expat"),
                .linkedLibrary("iconv"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
            ]),
    ]
)
