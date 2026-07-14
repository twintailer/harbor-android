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

    // The Swift plugin calls libmpv, but linking libmpv + its ~20 dependency
    // xcframeworks (ffmpeg, libplacebo, MoltenVK, …) at the cargo cdylib stage
    // is brittle. Instead leave the mpv symbols undefined in the cdylib and let
    // them bind at load time from the frameworks the app bundle embeds (the CI
    // Xcode-project patch links + embeds every MPVKit xcframework). This is the
    // standard approach for iOS plugin dylibs.
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "ios" {
        println!("cargo:rustc-link-arg=-Wl,-undefined,dynamic_lookup");
    }
}
