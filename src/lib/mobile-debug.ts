// Diagnosing mobile-only hangs (the player back-button freeze) is hard because
// once the main thread blocks, the WKWebView can no longer paint — an on-screen
// overlay written at the moment of the freeze never shows. So every step is
// ALSO persisted to localStorage synchronously (setItem survives even if the
// app is force-quit a millisecond later), and the last saved log is surfaced in
// an overlay on the NEXT launch. The final line recorded before the freeze
// pinpoints exactly which step blocked.
//
// Disable everything with localStorage "harbor.debugOverlay" = "0".

import { isMobileTauri } from "@/lib/platform";

const KEY = "harbor.exitLog";
const LINES: string[] = [];
let el: HTMLDivElement | null = null;
let enabled: boolean | null = null;

function isEnabled(): boolean {
  if (enabled !== null) return enabled;
  try {
    if (localStorage.getItem("harbor.debugOverlay") === "0") {
      enabled = false;
      return false;
    }
  } catch {
    /* ignore */
  }
  enabled = isMobileTauri();
  return enabled;
}

function render(): void {
  if (typeof document === "undefined" || !document.body) return;
  if (!el) {
    el = document.createElement("div");
    el.setAttribute("data-harbor-debug", "1");
    el.style.cssText =
      "position:fixed;top:0;left:0;right:0;z-index:2147483647;" +
      "background:rgba(0,0,0,0.82);color:#39ff5a;" +
      "font:10px/1.35 ui-monospace,Menlo,monospace;padding:4px 6px;" +
      "pointer-events:none;white-space:pre-wrap;max-height:46vh;overflow:hidden;" +
      "-webkit-user-select:none;user-select:none";
    document.body.appendChild(el);
  }
  el.textContent = LINES.join("\n");
}

/** Reset the buffer so the next sequence is isolated (call on back tap). */
export function mclear(): void {
  if (!isEnabled()) return;
  LINES.length = 0;
  try {
    localStorage.removeItem(KEY);
  } catch {
    /* ignore */
  }
}

/** Append a diagnostic line: paints an overlay AND persists synchronously. */
export function mlog(msg: string): void {
  if (!isEnabled()) return;
  const t = typeof performance !== "undefined" ? performance.now() / 1000 : 0;
  LINES.push(`${t.toFixed(2)}  ${msg}`);
  if (LINES.length > 24) LINES.shift();
  // Persist first — this is what survives a freeze/force-quit.
  try {
    localStorage.setItem(KEY, LINES.join("\n"));
  } catch {
    /* ignore */
  }
  render();
}

/**
 * On launch, show the log captured right before the previous run froze, with a
 * tap-to-dismiss + clear affordance. Call once from the entry point.
 */
export function showPreviousExitLog(): void {
  if (!isEnabled()) return;
  let prev = "";
  try {
    prev = localStorage.getItem(KEY) ?? "";
  } catch {
    /* ignore */
  }
  if (!prev.trim()) return;
  const box = document.createElement("div");
  box.style.cssText =
    "position:fixed;inset:0;z-index:2147483647;background:rgba(0,0,0,0.92);" +
    "color:#39ff5a;font:12px/1.5 ui-monospace,Menlo,monospace;padding:48px 16px 16px;" +
    "white-space:pre-wrap;overflow:auto;-webkit-user-select:text;user-select:text";
  box.textContent =
    "LAST EXIT LOG (tap to dismiss)\nlast line = where it froze\n\n" + prev;
  box.addEventListener("click", () => {
    try {
      localStorage.removeItem(KEY);
    } catch {
      /* ignore */
    }
    box.remove();
  });
  const mount = () => document.body && document.body.appendChild(box);
  if (document.body) mount();
  else window.addEventListener("DOMContentLoaded", mount, { once: true });
}
