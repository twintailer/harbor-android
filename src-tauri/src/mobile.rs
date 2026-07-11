//! Mobile (iOS/Android) entry point.
//!
//! The desktop build wires up libmpv, tray, auxiliary windows, Discord IPC and
//! sidecar binaries — none of which exist on mobile. This builder registers the
//! platform-neutral feature set: the stream proxy, the harbor-core stream
//! engine, casting (Chromecast/DLNA/Roku/AirPlay targets on the LAN), the
//! torrent engine, downloads, the Cloudflare watch-party relay and the
//! settings store. Playback happens in the webview via the HTML5 player; the
//! frontend falls back to it automatically when `mpv_probe` is unavailable.

use crate::{
    cast, cast_server, cf_relay, dlna, download, http_fetch, local_lib, power, settings_store,
    stream_proxy, streams, stremio_auth, sub_extract, subsync, torrent_engine, trailer, transcode,
    web_server,
};

pub fn run() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    trailer::sweep_cache();
    let proxy_state = tauri::async_runtime::block_on(stream_proxy::ProxyState::start())
        .unwrap_or_else(|e| {
            eprintln!("[stream-proxy] failed to start: {}", e);
            stream_proxy::ProxyState::placeholder()
        });
    let builder = tauri::Builder::default();
    #[cfg(target_os = "ios")]
    let builder = builder.plugin(tauri_plugin_native_player::init());
    builder
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_process::init())
        .manage(proxy_state)
        .manage(download::DownloadState::new())
        .setup(|app| {
            let handle = tauri::Manager::app_handle(app).clone();
            cast_server::ensure_started_on_setup(&handle);
            torrent_engine::ensure_started_on_setup(&handle);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            crate::harbor_flush_done,
            crate::close_aux_windows,
            crate::save_text_file,
            crate::harbor_take_pending_file,
            crate::deeplink_set_stremio,
            crate::deeplink_is_stremio_registered,
            crate::harbor_set_webview_memory_low,
            crate::harbor_set_webview_visible,
            crate::harbor_try_suspend_webview,
            crate::harbor_resume_webview,
            power::power_inhibit,
            settings_store::settings_read,
            settings_store::settings_write,
            http_fetch::harbor_fetch,
            stream_proxy::proxy_register,
            stream_proxy::proxy_unregister,
            stream_proxy::proxy_gc_idle,
            cf_relay::cf_list_accounts,
            cf_relay::cf_deploy_relay,
            cf_relay::cf_delete_relay,
            cf_relay::cf_relay_status,
            trailer::fetch_trailer,
            download::download_start,
            download::download_cancel,
            streams::streams_run_pipeline,
            streams::streams_parse,
            streams::streams_core_version,
            local_lib::harbor_scan_folder,
            stremio_auth::stremio_auth_start,
            subsync::moviehash::compute_moviehash,
            subsync::sync_subtitle,
            sub_extract::subtitle_extract,
            cast::cast_discover,
            cast::cast_load,
            cast::cast_play,
            cast::cast_pause,
            cast::cast_seek,
            cast::cast_stop,
            cast::cast_status,
            dlna::lan_ip,
            cast_server::stop_stremio_sidecar,
            cast_server::cast_server_status,
            cast_server::cast_server_restart,
            cast_server::cast_server_stop,
            web_server::web_serve_start,
            web_server::web_serve_stop,
            web_server::web_serve_status,
            torrent_engine::torrent_engine_status,
            torrent_engine::torrent_engine_add,
            torrent_engine::torrent_engine_select,
            torrent_engine::torrent_engine_stats,
            torrent_engine::torrent_engine_remove,
            torrent_engine::torrent_engine_selftest,
            torrent_engine::torrent_engine_restart,
            torrent_engine::torrent_engine_hard_reset,
            torrent_engine::torrent_engine_set_options,
            transcode::cast_ffmpeg_present,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
