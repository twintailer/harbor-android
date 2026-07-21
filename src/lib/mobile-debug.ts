// Diagnosing mobile-only hangs (the player back-button freeze) is hard because
// once the main thread blocks, the WKWebView can no longer paint — an on-screen
// overlay written at the moment of the freeze never shows. So every step is
// ALSO persisted to localStorage synchronously (setItem survives even if the
// app is force-quit a millisecond later), and the last saved log is surfaced in
// an overlay on the NEXT launch. The final line recorded before the freeze
// pinpoints exactly which step blocked.
//
// Default: OFF everywhere — the freeze class it was built to catch is fixed,
// and the green launch overlay confused daily use. Re-enable via
// Settings → Advanced → "Player debug log" (persists as localStorage
// "harbor.debugOverlay" = "1", read synchronously here because this module
// runs before the settings store is hydrated).

const KEY = "harbor.exitLog";
const FLAG_KEY = "harbor.debugOverlay";
const LINES: string[] = [];
let enabled: boolean | null = null;

function isEnabled(): boolean {
  if (enabled !== null) return enabled;
  try {
    enabled = localStorage.getItem(FLAG_KEY) === "1";
  } catch {
    enabled = false;
  }
  return enabled;
}

/** Settings toggle hook: flip the synchronous flag and apply immediately. */
export function setMobileDebugEnabled(on: boolean): void {
  enabled = on;
  try {
    localStorage.setItem(FLAG_KEY, on ? "1" : "0");
    if (!on) localStorage.removeItem(KEY);
  } catch {
    /* ignore */
  }
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

/**
 * Append a diagnostic line, persisted synchronously (setItem survives even if
 * the app freezes a millisecond later). No live overlay — it covered the
 * player's back button; the log is only surfaced on the NEXT launch.
 */
export function mlog(msg: string): void {
  if (!isEnabled()) return;
  const t = typeof performance !== "undefined" ? performance.now() / 1000 : 0;
  LINES.push(`${t.toFixed(2)}  ${msg}`);
  if (LINES.length > 24) LINES.shift();
  try {
    localStorage.setItem(KEY, LINES.join("\n"));
  } catch {
    /* ignore */
  }
}

/**
 * On launch, show the log captured right before the previous run froze, with a
 * tap-to-dismiss + clear affordance. Call once from the entry point.
 *
 * Merges TWO sources: the JS exit log (localStorage, written by the webview)
 * and the native probe log (UserDefaults, written by the Swift plugin without
 * any webview involvement). If "js alive" heartbeats stop while "main alive"
 * probes continue, the WebContent process hung; the reverse means the native
 * main thread froze.
 */
export function showPreviousExitLog(): void {
  if (!isEnabled()) return;
  let prev = "";
  try {
    prev = localStorage.getItem(KEY) ?? "";
  } catch {
    /* ignore */
  }
  void (async () => {
    let native = "";
    try {
      const { invoke } = await import("@tauri-apps/api/core");
      const res = (await invoke("plugin:native-player|exit_probe")) as { text?: string } | null;
      native = res?.text ?? "";
    } catch {
      /* plugin unavailable (web/desktop) */
    }
    if (!prev.trim() && !native.trim()) return;
    const box = document.createElement("div");
    box.style.cssText =
      "position:fixed;inset:0;z-index:2147483647;background:rgba(0,0,0,0.92);" +
      "color:#39ff5a;font:12px/1.5 ui-monospace,Menlo,monospace;padding:48px 16px 16px;" +
      "white-space:pre-wrap;overflow:auto;-webkit-user-select:text;user-select:text";
    box.textContent =
      "LAST EXIT LOG (tap to dismiss)\nlast line = where it froze\n\n" +
      prev +
      (native.trim() ? "\n\n--- NATIVE PROBE (webview-independent) ---\n" + native : "");
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
  })();
}
