//! Native video playback for the mobile shell. On iOS a VLCKit media player
//! renders into a UIView placed behind the (transparent) webview, mirroring
//! the desktop libmpv embed. Commands proxy to the Swift plugin; playback
//! state flows back to JS via plugin events ("status" and "time").

use serde::{Deserialize, Serialize};
use tauri::{
    plugin::{Builder, TauriPlugin},
    Runtime,
};

#[cfg(target_os = "ios")]
use tauri::{plugin::PluginHandle, AppHandle, Manager};

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_native_player);

#[cfg(target_os = "ios")]
struct NativePlayer<R: Runtime>(PluginHandle<R>);

#[derive(Debug, Serialize, Deserialize)]
pub struct ProbeResponse {
    pub available: bool,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoadArgs {
    pub url: String,
    #[serde(default)]
    pub start_at_sec: Option<f64>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeekArgs {
    pub sec: f64,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VolumeArgs {
    pub volume: f64,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MutedArgs {
    pub muted: bool,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RateArgs {
    pub rate: f64,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackArgs {
    pub id: i32,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtitleArgs {
    pub url: String,
    #[serde(default)]
    pub select: bool,
}

macro_rules! proxy {
    ($app:ident, $method:literal, $payload:expr) => {{
        #[cfg(target_os = "ios")]
        {
            let handle = &$app.state::<NativePlayer<R>>().0;
            handle
                .run_mobile_plugin::<serde_json::Value>($method, $payload)
                .map(|_| ())
                .map_err(|e| e.to_string())
        }
        #[cfg(not(target_os = "ios"))]
        {
            let _ = &$app;
            let _ = $payload;
            Err(format!("{} is not supported on this platform", $method))
        }
    }};
}

#[tauri::command]
async fn probe<R: Runtime>(app: tauri::AppHandle<R>) -> Result<ProbeResponse, String> {
    #[cfg(target_os = "ios")]
    {
        app.state::<NativePlayer<R>>()
            .0
            .run_mobile_plugin::<ProbeResponse>("probe", ())
            .map_err(|e| e.to_string())
    }
    #[cfg(not(target_os = "ios"))]
    {
        let _ = &app;
        Ok(ProbeResponse { available: false })
    }
}

#[tauri::command]
async fn load<R: Runtime>(app: tauri::AppHandle<R>, args: LoadArgs) -> Result<(), String> {
    proxy!(app, "load", args)
}

#[tauri::command]
async fn play<R: Runtime>(app: tauri::AppHandle<R>) -> Result<(), String> {
    proxy!(app, "play", ())
}

#[tauri::command]
async fn pause<R: Runtime>(app: tauri::AppHandle<R>) -> Result<(), String> {
    proxy!(app, "pause", ())
}

#[tauri::command]
async fn stop<R: Runtime>(app: tauri::AppHandle<R>) -> Result<(), String> {
    // Fire and forget: even if VLC's stop takes long (slow input teardown),
    // it must never wedge an async-runtime worker or delay the UI exit.
    #[cfg(target_os = "ios")]
    {
        let handle = app.state::<NativePlayer<R>>().0.clone();
        std::thread::spawn(move || {
            let _ = handle.run_mobile_plugin::<serde_json::Value>("stop", ());
        });
        Ok(())
    }
    #[cfg(not(target_os = "ios"))]
    {
        let _ = &app;
        Err("stop is not supported on this platform".into())
    }
}

#[tauri::command]
async fn seek<R: Runtime>(app: tauri::AppHandle<R>, args: SeekArgs) -> Result<(), String> {
    proxy!(app, "seek", args)
}

#[tauri::command]
async fn set_volume<R: Runtime>(app: tauri::AppHandle<R>, args: VolumeArgs) -> Result<(), String> {
    proxy!(app, "setVolume", args)
}

#[tauri::command]
async fn set_muted<R: Runtime>(app: tauri::AppHandle<R>, args: MutedArgs) -> Result<(), String> {
    proxy!(app, "setMuted", args)
}

#[tauri::command]
async fn set_rate<R: Runtime>(app: tauri::AppHandle<R>, args: RateArgs) -> Result<(), String> {
    proxy!(app, "setRate", args)
}

#[tauri::command]
async fn set_audio_track<R: Runtime>(app: tauri::AppHandle<R>, args: TrackArgs) -> Result<(), String> {
    proxy!(app, "setAudioTrack", args)
}

#[tauri::command]
async fn set_subtitle_track<R: Runtime>(app: tauri::AppHandle<R>, args: TrackArgs) -> Result<(), String> {
    proxy!(app, "setSubtitleTrack", args)
}

#[tauri::command]
async fn add_subtitle<R: Runtime>(app: tauri::AppHandle<R>, args: SubtitleArgs) -> Result<(), String> {
    proxy!(app, "addSubtitle", args)
}

#[tauri::command]
async fn lock_landscape<R: Runtime>(app: tauri::AppHandle<R>) -> Result<(), String> {
    proxy!(app, "lockLandscape", ())
}

#[tauri::command]
async fn unlock_orientation<R: Runtime>(app: tauri::AppHandle<R>) -> Result<(), String> {
    proxy!(app, "unlockOrientation", ())
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProbeLogArgs {
    pub msg: String,
}

/// JS-side breadcrumb into the webview-independent UserDefaults probe log.
#[tauri::command]
async fn probe_log<R: Runtime>(app: tauri::AppHandle<R>, args: ProbeLogArgs) -> Result<(), String> {
    proxy!(app, "probeLog", args)
}

/// Resolves only if the native main thread is alive (the Swift side hops the
/// resolve through the main queue). The CI autotest polls this to pinpoint
/// the moment the main thread wedges.
#[tauri::command]
async fn main_ping<R: Runtime>(app: tauri::AppHandle<R>) -> Result<(), String> {
    proxy!(app, "mainPing", ())
}

/// Returns (and clears) the webview-independent native exit-probe log the
/// Swift side persisted via UserDefaults — used to tell whether a freeze
/// killed the native main thread or the WebContent process.
#[tauri::command]
async fn exit_probe<R: Runtime>(app: tauri::AppHandle<R>) -> Result<serde_json::Value, String> {
    #[cfg(target_os = "ios")]
    {
        app.state::<NativePlayer<R>>()
            .0
            .run_mobile_plugin::<serde_json::Value>("exitProbe", ())
            .map_err(|e| e.to_string())
    }
    #[cfg(not(target_os = "ios"))]
    {
        let _ = &app;
        Ok(serde_json::json!({ "text": "" }))
    }
}

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("native-player")
        .invoke_handler(tauri::generate_handler![
            probe,
            load,
            play,
            pause,
            stop,
            seek,
            set_volume,
            set_muted,
            set_rate,
            set_audio_track,
            set_subtitle_track,
            add_subtitle,
            lock_landscape,
            unlock_orientation,
            exit_probe,
            main_ping,
            probe_log,
        ])
        .setup(|_app, _api| {
            #[cfg(target_os = "ios")]
            {
                let handle: PluginHandle<R> = _api.register_ios_plugin(init_plugin_native_player)?;
                let app: &AppHandle<R> = _app;
                app.manage(NativePlayer(handle));
            }
            Ok(())
        })
        .build()
}
