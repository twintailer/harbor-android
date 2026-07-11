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
];

fn main() {
    tauri_plugin::Builder::new(COMMANDS)
        .ios_path("ios")
        .build();
}
