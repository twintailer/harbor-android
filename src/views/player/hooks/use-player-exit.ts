import { useCallback, type RefObject } from "react";
import { clearOnePickerCache } from "@/lib/picker-cache";
import { clearPlayback, readPlayback, savePlayback, streamMatchesEntry } from "@/lib/playback-history";
import type { PlayerBridge } from "@/lib/player/bridge";
import { getPlaybackPosition } from "@/lib/player/playback-clock";
import { saveResumeMs } from "@/lib/resume";
import { exitWindowFullscreenOnPlayerClose } from "@/lib/fullscreen-state";
import type { PartialSyncState } from "@/lib/together/provider";
import { useView, type PlayerSrc, type PlayerStreamRef } from "@/lib/view";
import { mlog } from "@/lib/mobile-debug";
import { MAX_AUTORETRY_ATTEMPTS } from "../player-utils";

const REMEMBER_MIN_SEC = 30;

export function usePlayerExit(params: {
  src: PlayerSrc;
  season: number | undefined;
  episode: number | undefined;
  bridgeRef: RefObject<PlayerBridge | null>;
  liveUrl: string;
  liveStreamRef: PlayerStreamRef | undefined;
  inRoom: boolean;
  isHost: boolean;
  instantPlay: boolean;
  captureExitSnapshot: () => Promise<void>;
  exitPip: () => Promise<void>;
  castActiveRef: RefObject<boolean>;
  stopCast: () => Promise<void>;
  publishState: (state: PartialSyncState) => void;
  notifyHostLeaving: () => void;
  clearInvite: () => void;
  exitPlayback: () => void;
  openPicker: ReturnType<typeof useView>["openPicker"];
}) {
  const {
    src,
    season,
    episode,
    bridgeRef,
    liveUrl,
    liveStreamRef,
    inRoom,
    isHost,
    instantPlay,
    captureExitSnapshot,
    exitPip,
    castActiveRef,
    stopCast,
    publishState,
    notifyHostLeaving,
    clearInvite,
    exitPlayback,
    openPicker,
  } = params;

  const closePlayer = useCallback(async () => {
    mlog("closePlayer: start");
    // Save resume position synchronously first — it must never be skipped.
    const pos = getPlaybackPosition();
    if (Number.isFinite(pos) && pos > 0) {
      saveResumeMs(src.meta.id, pos * 1000, season, episode);
      if (liveStreamRef && pos >= REMEMBER_MIN_SEC) {
        savePlayback(
          src.meta.id,
          { ...liveStreamRef, url: liveUrl || src.url, title: src.meta.name },
          season,
          episode,
        );
      }
    }
    // Everything else is best-effort cleanup. If any of it hangs (a native
    // snapshot/PiP/cast call that never resolves on mobile), the player must
    // still close — otherwise the app looks frozen. Cap the whole batch and
    // always run exitPlayback() in the finally.
    try {
      await Promise.race([
        (async () => {
          mlog("closePlayer: snapshot…");
          await captureExitSnapshot().catch(() => {});
          mlog("closePlayer: exitPip…");
          await exitPip().catch(() => {});
          if (castActiveRef.current) {
            mlog("closePlayer: stopCast…");
            await stopCast().catch(() => {});
          }
          mlog("closePlayer: exitFullscreen…");
          await exitWindowFullscreenOnPlayerClose().catch(() => {});
          if (inRoom && isHost) {
            mlog("closePlayer: room teardown…");
            publishState({
              mediaId: null,
              mediaTitle: null,
              episode: null,
              posterUrl: null,
              positionSeconds: 0,
              playing: false,
            });
            notifyHostLeaving();
            clearInvite();
          }
          mlog("closePlayer: cleanup done");
        })(),
        new Promise<void>((resolve) => setTimeout(resolve, 700)),
      ]);
    } finally {
      mlog("closePlayer: exitPlayback()");
      exitPlayback();
      mlog("closePlayer: exitPlayback returned");
      // WebContent-side liveness ticker: if these keep landing in the exit
      // log while the native probes stop, the webview survived and the
      // native main thread is what froze — and vice versa.
      for (const ms of [500, 1000, 2000, 3000, 5000]) {
        setTimeout(() => mlog(`js alive +${ms}ms`), ms);
      }
    }
  }, [captureExitSnapshot, exitPlayback, src.meta.id, src.meta.name, season, episode, inRoom, isHost, notifyHostLeaving, clearInvite, publishState, exitPip, liveStreamRef, liveUrl, src.url, stopCast, castActiveRef]);

  const onStubEject = useCallback(() => {
    const nextAttempt = (src.attempt ?? 0) + 1;
    if (bridgeRef.current) {
      bridgeRef.current.destroy();
      bridgeRef.current = null;
    }
    if (src.streamRef) {
      const remembered = readPlayback(src.meta.id, season, episode);
      if (remembered && streamMatchesEntry(src.streamRef, remembered)) {
        clearPlayback(src.meta.id, season, episode);
      }
    }
    if (nextAttempt > MAX_AUTORETRY_ATTEMPTS) {
      void closePlayer();
      return;
    }
    if (nextAttempt >= 2) clearOnePickerCache(src.meta, src.episode);
    openPicker(
      src.meta,
      src.episode,
      instantPlay || inRoom ? { autoPlay: true, attempt: nextAttempt } : { autoPlay: false },
    );
  }, [src.attempt, src.meta, src.episode, src.streamRef, season, episode, openPicker, instantPlay, inRoom, closePlayer, bridgeRef]);

  return { closePlayer, onStubEject };
}
