# Harbor auf iOS

Harbor ist eine Tauri-2-App — dieselbe Codebasis läuft auf iOS als natives App-Bundle
mit dem kompletten React-Frontend. Der Build passiert komplett über GitHub Actions
(iOS-Apps lassen sich nur auf macOS kompilieren, ein eigener Mac ist aber nicht nötig).

## Build über GitHub starten

1. Repo auf GitHub pushen (falls noch nicht geschehen).
2. Workflow starten — entweder im Browser über **Actions → ios-build → Run workflow**
   oder per CLI:

   ```sh
   gh workflow run ios-build.yml
   ```

3. Nach ~15–25 Minuten liegt unter dem Workflow-Run das Artifact **harbor-ios**
   mit `Harbor_<version>_unsigned.ipa`.

## IPA installieren (Sideloading)

Die IPA ist unsigniert und muss mit der eigenen (kostenlosen) Apple-ID signiert werden:

- **AltStore** (altstore.io) oder **Sideloadly** (sideloadly.io): IPA auswählen,
  Apple-ID angeben — das Tool signiert und installiert aufs iPhone/iPad.
- **Xcode** (falls Mac vorhanden): Devices & Simulators → IPA aufs Gerät ziehen
  (vorher mit eigenem Zertifikat via `codesign` signieren).
- Mit kostenloser Apple-ID gilt die Signatur 7 Tage, danach neu signieren
  (AltStore macht das automatisch im Hintergrund).

## Was auf iOS funktioniert

- Komplette Oberfläche: Home, Discover, Filme, Serien, Anime, Kalender, Bibliothek,
  Addons-Store, Einstellungen, Theme-Engine
- Stremio-Login, Addons installieren/verwalten, TMDB/Trakt/OMDB-Integrationen
- Stream-Ranking-Engine (harbor-core, nativ in Rust kompiliert)
- Wiedergabe über den HTML5-Player (hls.js/mpegts.js) inkl. Untertitel,
  Live TV (M3U/Xtream) mit EPG
- Stream-Proxy, Torrent-Engine (librqbit), Downloads
- Casting an Chromecast, DLNA, Roku und AirPlay-Geräte im LAN¹
- Watch Parties über das eigene Cloudflare-Relay
- Deep Links (`harbor://`, `stremio://`)
- Safe-Area-Support (Notch/Home-Indicator), Hintergrund-Audio

¹ Geräte-Discovery per mDNS/SSDP benötigt auf iOS die Multicast-Entitlement, die
Apple nur auf Antrag vergibt. Ohne sie kann die Discovery auf manchen Geräten
eingeschränkt sein.

## Was auf iOS nicht verfügbar ist

Diese Features hängen an Desktop-Infrastruktur (libmpv, ffmpeg-Sidecars,
Mehrfenster-Betrieb) und sind auf iOS deaktiviert:

- Nativer libmpv-Player (HDR-Passthrough, Anime4K-Shader, SVP) — der Web-Player
  übernimmt automatisch
- DVR-Aufnahmen, Transcoding, Thumbnail-Vorschau auf der Seekbar
- Multiview (vier Fenster), separates PiP-Fenster (iOS-natives PiP des
  Video-Elements funktioniert), In-App-Browser-Fenster
- Discord Rich Presence, System-Tray, Song-Erkennung
- Auto-Updater (Updates kommen per neuem Sideload)

## Technischer Aufbau

- `src-tauri/src/mobile.rs` — Mobile-Einstiegspunkt, registriert nur die
  plattformneutralen Commands
- `src-tauri/src/lib.rs` — Desktop-Module hinter `#[cfg(desktop)]`
- `src-tauri/Cargo.toml` — Desktop-Dependencies (libmpv2, Updater, …) im Target
  `cfg(not(any(target_os = "ios", target_os = "android")))`
- `src-tauri/capabilities/mobile.json` — Capability-Set für iOS/Android
- `src-tauri/tauri.ios.conf.json` — überschreibt `externalBin`/Ressourcen
  (keine ffmpeg/yt-dlp-Sidecars auf iOS)
- `.github/workflows/ios-build.yml` — CI-Build (init → Info.plist-Patch →
  xcodebuild unsigniert → IPA-Artifact)

## Signierter Build (optional)

Wer einen Apple-Developer-Account (99 €/Jahr) hat, kann in
`src-tauri/tauri.conf.json` unter `bundle > iOS > developmentTeam` die Team-ID
eintragen und lokal auf einem Mac `pnpm tauri ios build` ausführen — das erzeugt
eine direkt installierbare, signierte IPA.
