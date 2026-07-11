const COMMANDS: &[&str] = &[
    "probe",
    "load",
    "play",
    "pause",
    "stop",
    "seek",
    "set_volume",
    "set_muted",
    "set_rate",
    "set_audio_track",
    "set_subtitle_track",
    "add_subtitle",
    "lock_landscape",
    "unlock_orientation",
    // addPluginListener on the JS side goes through these built-ins.
    "registerListener",
    "remove_listener",
];

fn main() {
    tauri_plugin::Builder::new(COMMANDS)
        .ios_path("ios")
        .build();

    // The Swift side only compiles against interop declarations; the actual
    // MobileVLCKit symbols must be present when cargo links the cdylib. CI
    // extracts the device slice of the xcframework to src-tauri/frameworks-ios
    // (see .github/workflows/ios-build.yml). Without it, iOS builds fail at
    // link time — which is the correct signal that the framework is missing.
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "ios" {
        let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let fw_dir = manifest.join("../frameworks-ios");
        println!("cargo:rerun-if-changed={}", fw_dir.display());
        if fw_dir.join("MobileVLCKit.framework").exists() {
            println!("cargo:rustc-link-search=framework={}", fw_dir.display());
            println!("cargo:rustc-link-lib=framework=MobileVLCKit");
            for fw in [
                "QuartzCore",
                "CoreText",
                "AVFoundation",
                "Security",
                "CFNetwork",
                "AudioToolbox",
                "OpenGLES",
                "CoreGraphics",
                "VideoToolbox",
                "CoreMedia",
            ] {
                println!("cargo:rustc-link-lib=framework={fw}");
            }
            for lib in ["c++", "xml2", "z", "bz2", "iconv"] {
                println!("cargo:rustc-link-lib={lib}");
            }
        } else {
            println!(
                "cargo:warning=MobileVLCKit.framework not found in {}; iOS link will fail. Run the CI framework step or place the device slice there.",
                fw_dir.display()
            );
        }
    }
}
