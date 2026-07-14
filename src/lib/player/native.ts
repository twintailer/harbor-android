import { invoke, addPluginListener, type PluginListener } from "@tauri-apps/api/core";
import { mlog } from "@/lib/mobile-debug";
import {
  emptySnapshot,
  type PlayerBridge,
  type PlayerCapabilities,
  type PlayerSnapshot,
  type PlayerSource,
  type TrackInfo,
} from "./bridge";

const PLUGIN = "plugin:native-player|";

export async function probeNativePlayer(): Promise<boolean> {
  try {
    const res = await invoke<{ available: boolean }>(`${PLUGIN}probe`);
    return !!res?.available;
  } catch {
    return false;
  }
}

type StatusEvent = {
  status?: string;
  buffering?: boolean;
  durationSec?: number;
  rate?: number;
  audioTracks?: { id: number; label: string; selected: boolean }[];
  subtitleTracks?: { id: number; label: string; selected: boolean }[];
  videoWidth?: number;
  videoHeight?: number;
};

type TimeEvent = { positionSec?: number; durationSec?: number };

function toTracks(
  list: { id: number; label: string; selected: boolean }[] | undefined,
  kind: "audio" | "subtitle",
): TrackInfo[] {
  return (list ?? []).map((t) => ({
    id: String(t.id),
    label: t.label,
    kind,
    selected: t.selected,
  }));
}

/**
 * PlayerBridge backed by the native-player Tauri plugin: VLCKit decodes and
 * renders into a view behind the transparent webview, so any container/codec
 * (MKV, HEVC, …) plays on iOS. The HTML chrome stays on top, like the
 * desktop libmpv embed.
 */
export function createNativeBridge(): PlayerBridge {
  let snap: PlayerSnapshot = { ...emptySnapshot };
  const listeners = new Set<(s: PlayerSnapshot) => void>();
  let statusL: PluginListener | null = null;
  let timeL: PluginListener | null = null;
  let destroyed = false;
  let ended = false;

  const emit = () => {
    for (const fn of listeners) fn(snap);
  };
  const patch = (p: Partial<PlayerSnapshot>) => {
    snap = { ...snap, ...p };
    emit();
  };
  const call = (cmd: string, args?: Record<string, unknown>) =>
    invoke(`${PLUGIN}${cmd}`, args).catch((e) => {
      console.warn(`[native-player] ${cmd} failed`, e);
    });

  let debugL: PluginListener | null = null;
  void (async () => {
    debugL = await addPluginListener("native-player", "debug", (e: { msg?: string }) => {
      mlog(`native: ${e.msg ?? "?"}`);
    });
    statusL = await addPluginListener("native-player", "status", (e: StatusEvent) => {
      if (destroyed) return;
      const status =
        e.status === "ended" && !ended
          ? snap.positionSec > 0 && snap.durationSec > 0 && snap.positionSec > snap.durationSec - 10
            ? "ended"
            : snap.status
          : (e.status as PlayerSnapshot["status"]) ?? snap.status;
      if (status === "ended") ended = true;
      patch({
        status,
        buffering: !!e.buffering,
        durationSec: e.durationSec && e.durationSec > 0 ? e.durationSec : snap.durationSec,
        rate: e.rate || snap.rate,
        audioTracks: toTracks(e.audioTracks, "audio"),
        subtitleTracks: toTracks(e.subtitleTracks, "subtitle"),
        videoWidth: e.videoWidth ?? snap.videoWidth,
        videoHeight: e.videoHeight ?? snap.videoHeight,
        errorMessage: e.status === "error" ? "Native playback failed" : null,
        errorCode: e.status === "error" ? "decode" : null,
      });
    });
    timeL = await addPluginListener("native-player", "time", (e: TimeEvent) => {
      if (destroyed) return;
      patch({
        positionSec: e.positionSec ?? snap.positionSec,
        durationSec: e.durationSec && e.durationSec > 0 ? e.durationSec : snap.durationSec,
        status: snap.status === "loading" ? "playing" : snap.status,
        buffering: false,
      });
    });
  })();

  return {
    attach() {
      document.documentElement.dataset.nativeVideo = "1";
    },
    detach() {
      delete document.documentElement.dataset.nativeVideo;
    },
    async load(src: PlayerSource) {
      ended = false;
      patch({ ...emptySnapshot, status: "loading" });
      await invoke(`${PLUGIN}load`, {
        args: { url: src.url, startAtSec: src.startAtSec ?? 0 },
      });
      if (src.subtitles && src.subtitles.length > 0) {
        void call("add_subtitle", { args: { url: src.subtitles[0].url, select: false } });
      }
    },
    async play() {
      await call("play");
      patch({ status: "playing" });
    },
    pause() {
      void call("pause");
      patch({ status: "paused" });
    },
    seek(sec: number) {
      void call("seek", { args: { sec } });
      patch({ positionSec: sec });
    },
    setVolume(v: number) {
      void call("set_volume", { args: { volume: v } });
      patch({ volume: v });
    },
    setMuted(m: boolean) {
      void call("set_muted", { args: { muted: m } });
      patch({ muted: m });
    },
    setRate(r: number) {
      void call("set_rate", { args: { rate: r } });
      patch({ rate: r });
    },
    setAudioTrack(id: string) {
      void call("set_audio_track", { args: { id: Number(id) } });
    },
    setSubtitleTrack(id: string | null) {
      void call("set_subtitle_track", { args: { id: id == null ? -1 : Number(id) } });
    },
    setSubVisible(on: boolean) {
      if (!on) void call("set_subtitle_track", { args: { id: -1 } });
    },
    setSubDelay() {},
    setAudioDelay() {},
    setPanscan() {},
    setVideoZoom() {},
    setAspectOverride() {},
    setStretch() {},
    setVideoEq() {},
    setAnime4kShaders() {},
    async addSubtitle(url: string, _lang?: string, _title?: string, select = true) {
      await call("add_subtitle", { args: { url, select } });
      return true;
    },
    getSelectedTrackCues() {
      return null;
    },
    getSelectedTrackUrl() {
      return null;
    },
    setAudioNormalize() {},
    async screenshot() {
      return { ok: false, error: "not supported" };
    },
    setAbLoop() {},
    async requestPiP() {},
    async exitPiP() {},
    async requestFullscreen() {},
    async exitFullscreen() {},
    capabilities(): PlayerCapabilities {
      return {
        engine: "html5",
        pictureInPicture: false,
        airplay: false,
        chromecast: false,
        hdrPassthrough: false,
        hardwareDecode: true,
      };
    },
    subscribe(listener: (s: PlayerSnapshot) => void) {
      listeners.add(listener);
      listener(snap);
      return () => listeners.delete(listener);
    },
    destroy() {
      mlog("native.destroy: start");
      destroyed = true;
      delete document.documentElement.dataset.nativeVideo;
      mlog("native.destroy: invoke stop");
      void invoke(`${PLUGIN}stop`)
        .then(() => mlog("native.destroy: stop resolved"))
        .catch((e) => mlog(`native.destroy: stop rejected ${e}`));
      void statusL?.unregister();
      void timeL?.unregister();
      // Keep the debug listener alive briefly so the native stop()'s
      // begin/end events (fired after teardown) still reach the log.
      setTimeout(() => void debugL?.unregister(), 3000);
      listeners.clear();
      mlog("native.destroy: done");
    },
  };
}
