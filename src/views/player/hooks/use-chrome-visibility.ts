import { useCallback, useEffect, useRef, useState, type CSSProperties } from "react";
import { getSeekHovering, subscribeSeekHovering } from "@/lib/player/playback-clock";
import { isMobileTauri } from "@/lib/platform";
import {
  CHROME_HIDE_MS_PAUSED,
  CHROME_HIDE_MS_PLAYING,
  CHROME_HIDE_MS_PLAYING_TOUCH,
  CHROME_HIDE_MS_RESUME,
} from "../player-utils";

const UI_SCALE_ACTIVITY_EVENT = "harbor:ui-scale-activity";
const UI_SCALE_RESIZE_HOLD_MS = 700;

export function useChromeVisibility(params: {
  playing: boolean;
  drawMode: boolean;
  pipMode: boolean;
  setChromeHidden: (hidden: boolean) => void;
  keyboardPauseShowsControls: boolean;
}) {
  const { playing, drawMode, pipMode, setChromeHidden, keyboardPauseShowsControls } = params;
  const [chromeVisible, setChromeVisible] = useState(false);
  const lastInputKeyboardRef = useRef(false);
  const prevPlayingRef = useRef(playing);
  const chromeVisibleRef = useRef(false);
  useEffect(() => {
    chromeVisibleRef.current = chromeVisible;
  }, [chromeVisible]);

  const hideTimer = useRef<number | null>(null);
  const resizeTimer = useRef<number | null>(null);
  const resizingUiRef = useRef(false);
  const anyMenuOpenRef = useRef(false);
  const resumeHideRef = useRef(false);
  // Chrome visibility as it was when the current touch STARTED (see onMove).
  const visibleBeforeTouchRef = useRef(false);

  const wakeChrome = useCallback(() => {
    setChromeVisible(true);
    setChromeHidden(pipMode);
    if (hideTimer.current) window.clearTimeout(hideTimer.current);
    if (resizingUiRef.current || anyMenuOpenRef.current || getSeekHovering()) return;
    const playingWait = isMobileTauri() ? CHROME_HIDE_MS_PLAYING_TOUCH : CHROME_HIDE_MS_PLAYING;
    let wait = playing && !drawMode ? playingWait : CHROME_HIDE_MS_PAUSED;
    if (resumeHideRef.current) {
      resumeHideRef.current = false;
      wait = CHROME_HIDE_MS_RESUME;
    }
    hideTimer.current = window.setTimeout(() => {
      setChromeVisible(false);
      setChromeHidden(true);
    }, wait);
  }, [playing, drawMode, pipMode, setChromeHidden]);

  const hideForResume = useCallback(() => {
    resumeHideRef.current = true;
  }, []);

  /// Dismiss the chrome right now (touch shells: a second tap on the video).
  /// Menus keep it up, otherwise a tap would strand an open panel.
  const hideChrome = useCallback(() => {
    if (anyMenuOpenRef.current) return;
    if (hideTimer.current) window.clearTimeout(hideTimer.current);
    setChromeVisible(false);
    setChromeHidden(true);
  }, [setChromeHidden]);

  /// A tap on the video surface. First tap reveals the controls and leaves them
  /// up for the full window; tapping again while they were already up dismisses
  /// them. Decided from the pre-touch state, because the window-level
  /// touchstart listener has already woken the chrome by the time this runs.
  const touchToggleChrome = useCallback(() => {
    if (visibleBeforeTouchRef.current) hideChrome();
    else wakeChrome();
  }, [hideChrome, wakeChrome]);

  useEffect(() => {
    const playingChanged = prevPlayingRef.current !== playing;
    prevPlayingRef.current = playing;
    if (playingChanged && lastInputKeyboardRef.current && !keyboardPauseShowsControls) {
      if (hideTimer.current) window.clearTimeout(hideTimer.current);
      setChromeVisible(false);
      setChromeHidden(true);
    } else {
      wakeChrome();
    }
    const onMove = (e: Event) => {
      // Remember whether the chrome was already up BEFORE this touch revealed
      // it. Without this the tap handler saw the state this very listener had
      // just flipped and dismissed the chrome again a frame later.
      if (e.type === "touchstart") visibleBeforeTouchRef.current = chromeVisibleRef.current;
      lastInputKeyboardRef.current = false;
      wakeChrome();
    };
    const onPointerDown = () => {
      lastInputKeyboardRef.current = false;
    };
    const onKeyDown = () => {
      lastInputKeyboardRef.current = true;
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("touchstart", onMove);
    window.addEventListener("pointerdown", onPointerDown);
    window.addEventListener("keydown", onKeyDown);
    return () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("touchstart", onMove);
      window.removeEventListener("pointerdown", onPointerDown);
      window.removeEventListener("keydown", onKeyDown);
      if (hideTimer.current) window.clearTimeout(hideTimer.current);
      if (resizeTimer.current) window.clearTimeout(resizeTimer.current);
      setChromeHidden(false);
    };
  }, [wakeChrome, setChromeHidden, playing, keyboardPauseShowsControls]);

  useEffect(() => {
    const onScaleActivity = () => {
      resizingUiRef.current = true;
      setChromeVisible(true);
      setChromeHidden(pipMode);
      if (hideTimer.current) window.clearTimeout(hideTimer.current);
      if (resizeTimer.current) window.clearTimeout(resizeTimer.current);
      resizeTimer.current = window.setTimeout(() => {
        resizingUiRef.current = false;
        wakeChrome();
      }, UI_SCALE_RESIZE_HOLD_MS);
    };
    window.addEventListener(UI_SCALE_ACTIVITY_EVENT, onScaleActivity);
    return () => {
      window.removeEventListener(UI_SCALE_ACTIVITY_EVENT, onScaleActivity);
      if (resizeTimer.current) window.clearTimeout(resizeTimer.current);
    };
  }, [pipMode, setChromeHidden, wakeChrome]);

  useEffect(() => {
    const onLeave = (e: MouseEvent) => {
      if (e.relatedTarget) return;
      if (!playing || drawMode) return;
      if (anyMenuOpenRef.current || getSeekHovering()) return;
      if (hideTimer.current) window.clearTimeout(hideTimer.current);
      setChromeVisible(false);
      setChromeHidden(true);
    };
    document.addEventListener("mouseout", onLeave);
    return () => document.removeEventListener("mouseout", onLeave);
  }, [playing, drawMode, setChromeHidden]);

  useEffect(() => {
    const onBlur = () => {
      if (hideTimer.current) window.clearTimeout(hideTimer.current);
      setChromeVisible(false);
      setChromeHidden(true);
    };
    window.addEventListener("blur", onBlur);
    return () => window.removeEventListener("blur", onBlur);
  }, [setChromeHidden]);

  useEffect(
    () =>
      subscribeSeekHovering(() => {
        if (getSeekHovering()) {
          setChromeVisible(true);
          if (hideTimer.current) window.clearTimeout(hideTimer.current);
        } else {
          wakeChrome();
        }
      }),
    [wakeChrome],
  );

  const [anyMenuOpen, setAnyMenuOpen] = useState(false);
  useEffect(() => {
    anyMenuOpenRef.current = anyMenuOpen;
    if (anyMenuOpen) {
      setChromeVisible(true);
      if (hideTimer.current) window.clearTimeout(hideTimer.current);
    } else {
      wakeChrome();
    }
  }, [anyMenuOpen, wakeChrome]);

  const cursorStyle: CSSProperties = drawMode
    ? { cursor: "none" }
    : !chromeVisible && playing
      ? { cursor: "none" }
      : { cursor: "default" };

  return {
    chromeVisible,
    wakeChrome,
    hideForResume,
    hideChrome,
    touchToggleChrome,
    anyMenuOpen,
    setAnyMenuOpen,
    cursorStyle,
  };
}
