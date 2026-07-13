// Lightweight on-screen log for diagnosing mobile-only hangs (e.g. the player
// back-button freeze) where no console is reachable. The last line shown
// before the UI freezes pinpoints exactly which step blocked. Toggle off by
// setting localStorage "harbor.debugOverlay" to "0".

import { isMobileTauri } from "@/lib/platform";

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

/** Append a diagnostic line to the on-screen overlay (mobile only). */
export function mlog(msg: string): void {
  if (!isEnabled()) return;
  const t = typeof performance !== "undefined" ? performance.now() / 1000 : 0;
  LINES.push(`${t.toFixed(2)}  ${msg}`);
  if (LINES.length > 16) LINES.shift();
  render();
}
