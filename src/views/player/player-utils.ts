import { createHtml5Bridge } from "@/lib/player/html5";
import { createMpvBridge, probeMpv, type MpvRect } from "@/lib/player/mpv";
import { createNativeBridge, lastNativeProbeError, probeNativePlayer } from "@/lib/player/native";
import type { PlayerBridge } from "@/lib/player/bridge";
import { mlog } from "@/lib/mobile-debug";
import { isLinuxDesktop, isMacDesktop, isMobileTauri } from "@/lib/platform";

export const SYNC_DRIFT_TOLERANCE_S = 0.6;
export const SYNC_SUPPRESS_MS = 1400;
export const SYNC_PLAY_LOOKAHEAD_S = 0.4;
export const SYNC_MAX_AGE_S = 30;
export const SYNC_SEEK_JUMP_S = 10;
export const HOST_HEARTBEAT_MS = 1000;
export const GUEST_ESCAPE_MS = 45_000;
export const READY_STALE_MS = 20_000;
export const SEEK_APPLY_DEBOUNCE_MS = 120;
export const DURATION_MISMATCH_S = 4;
export const ROOM_STALL_MS = 9000;
export const SLOW_LOAD_MS = 50_000;
export const STUCK_AUTORETRY_MS = 18_000;
export const BLACK_SCREEN_GRACE_MS = 6_000;
export const MAX_AUTORETRY_ATTEMPTS = 5;
export const CHROME_HIDE_MS_PLAYING = 1800;
// Touch shells: a tap is a deliberate "show me the controls", and there is no
// pointer to keep them alive by moving it — 1.8s felt like they vanished
// instantly. Give a thumb time to travel to the centre button.
export const CHROME_HIDE_MS_PLAYING_TOUCH = 4000;
export const CHROME_HIDE_MS_PAUSED = 4500;
export const CHROME_HIDE_MS_RESUME = 1000;

export function round2(v: number): number {
  return Math.round(v * 100) / 100;
}

export function embedFlags(
  engine: "html5" | "mpv",
  mpvEmbed: boolean,
  videoWidth: number,
  videoHeight: number,
): { mpvEmbedWindowsActive: boolean; stageBg: string } {
  const embedOn = engine === "mpv" && mpvEmbed;
  const mpvEmbedWindowsActive =
    embedOn &&
    typeof navigator !== "undefined" &&
    navigator.userAgent.toLowerCase().includes("windows");
  const hasFrame = videoWidth > 0 && videoHeight > 0;
  const macShowing = embedOn && isMacDesktop() && hasFrame;
  const linuxShowing = embedOn && isLinuxDesktop() && hasFrame;
  return {
    mpvEmbedWindowsActive,
    stageBg: mpvEmbedWindowsActive || macShowing || linuxShowing ? "" : "bg-black",
  };
}

export function formatNames(names: string[]): string {
  if (names.length === 0) return "";
  if (names.length === 1) return names[0];
  if (names.length === 2) return `${names[0]} and ${names[1]}`;
  return `${names.slice(0, -1).join(", ")}, and ${names[names.length - 1]}`;
}

export async function pickBridge(
  want: "auto" | "html5" | "mpv",
  notWebReady: boolean,
  mpvOpts: {
    anime4k: boolean;
    hdrToSdr: boolean;
    embed?: boolean;
    anime4kShaders?: string[];
    d3d11Flip?: boolean;
    macEdr?: boolean;
    extraOptions?: string;
    getEmbedRect?: () => Promise<MpvRect | null> | MpvRect | null;
  },
): Promise<{ bridge: PlayerBridge; engine: "html5" | "mpv" }> {
  if (want === "html5") return { bridge: createHtml5Bridge(), engine: "html5" };
  // Mobile shells: prefer the native VLCKit backend (plays MKV/HEVC/etc.),
  // fall back to in-webview HTML5 decode when the plugin is unavailable.
  if (isMobileTauri()) {
    if (await probeNativePlayer()) {
      mlog("pickBridge: native player");
      return { bridge: createNativeBridge(), engine: "html5" };
    }
    // The in-webview decoder cannot play the containers Stremio serves, so this
    // fallback hangs at "connecting" rather than degrading gracefully. Make the
    // reason loud instead of silently handing over to a bridge that can't work.
    const why = lastNativeProbeError() ?? "unknown";
    mlog(`pickBridge: NATIVE PLAYER UNAVAILABLE (${why}) — falling back to html5`);
    console.warn(`[harbor] native player unavailable (${why}); in-webview decode will fail for most streams`);
    return { bridge: createHtml5Bridge(), engine: "html5" };
  }
  if (want === "mpv") {
    const probe = await probeMpv();
    if (probe.available) return { bridge: createMpvBridge(mpvOpts), engine: "mpv" };
    console.warn("[harbor] mpv requested but libmpv probe failed; falling back to in-webview html5 decode (high memory)");
    return { bridge: createHtml5Bridge(), engine: "html5" };
  }
  const isDesktop =
    typeof window !== "undefined" && "__TAURI_INTERNALS__" in window && !isMobileTauri();
  if (isDesktop || notWebReady) {
    const probe = await probeMpv();
    if (probe.available) return { bridge: createMpvBridge(mpvOpts), engine: "mpv" };
    if (isDesktop) console.warn("[harbor] desktop libmpv probe failed; falling back to in-webview html5 decode (high memory)");
  }
  return { bridge: createHtml5Bridge(), engine: "html5" };
}
