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

    // libmpv is linked into the app by Xcode (MPVKit SwiftPM package), not by
    // cargo. Its symbols stay undefined in the cdylib and bind at load time via
    // `-Wl,-undefined,dynamic_lookup` — but that link-arg is emitted from the
    // FINAL cdylib crate (src-tauri/build.rs), because a dependency build
    // script's rustc-link-arg does not propagate to the final link.
}
