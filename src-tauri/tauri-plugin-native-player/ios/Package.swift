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
        // Interop declarations only; MobileVLCKit.xcframework is linked by the
        // app's Xcode project (SwiftPM CLI builds cannot use binary targets).
        .target(
            name: "CVLC",
            path: "Sources/CVLC",
            publicHeadersPath: "include"),
        .target(
            name: "tauri-plugin-native-player",
            dependencies: [
                .byName(name: "Tauri"),
                "CVLC",
            ],
            path: "Sources/NativePlayer",
            linkerSettings: [
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("OpenGLES"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedLibrary("c++"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
            ]),
    ]
)
