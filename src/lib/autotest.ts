// CI-only freeze reproduction harness. Active ONLY when the build carries
// VITE_HARBOR_AUTOTEST_URL (set by .github/workflows/ios-test.yml for the
// simulator run) — device/production builds never define it, so this module
// is dead code there.
//
// It replays the exact exit sequence that freezes on the phone (lock
// landscape → load → play → destroy/halt → unlock orientation → home-style
// re-render) while streaming beacons to an HTTP listener on the runner:
//   - "js"    beat every 500ms   → proves the WebContent process is alive
//   - "native" beat every 500ms  → main_ping round-trip; stops the moment the
//                                  native MAIN thread wedges
// The workflow watches the beat log; when native beats stop it samples the
// app process to capture the wedged thread's stack.

import { isMobileTauri } from "./platform";

const BEAT_PORT = 8765;

type InvokeFn = (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;
let invokeRef: InvokeFn | null = null;

function beacon(step: string): void {
  const url = `http://127.0.0.1:${BEAT_PORT}/beat?step=${encodeURIComponent(step)}&t=${Date.now()}`;
  // Primary transport: the Rust-side harbor_fetch. In production the page
  // origin is tauri://localhost and WKWebView blocks plain fetch() to
  // http://127.0.0.1 as mixed content — that silently ate every beacon on
  // the first prod-sim run.
  if (invokeRef) {
    void invokeRef("harbor_fetch", {
      args: { url, method: "GET", headers: {}, timeoutMs: 3000 },
    }).catch(() => {});
  }
  // Fallback for dev builds (http origin): plain fetch works there.
  void fetch(url, { method: "GET", cache: "no-store" }).catch(() => {});
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function maybeRunAutotest(): void {
  const url = (import.meta as unknown as { env?: Record<string, string | undefined> }).env
    ?.VITE_HARBOR_AUTOTEST_URL;
  if (!url || !isMobileTauri()) return;
  void (async () => {
    const { invoke } = await import("@tauri-apps/api/core");
    invokeRef = invoke as InvokeFn;
    beacon("boot");

    setInterval(() => beacon("js"), 500);
    setInterval(() => {
      void invoke("plugin:native-player|main_ping")
        .then(() => beacon("native"))
        .catch((e) => beacon(`native-err:${String(e).slice(0, 60)}`));
    }, 500);

    await sleep(4000); // let the app settle like a real launch
    try {
      beacon("phase:lock");
      await invoke("plugin:native-player|lock_landscape").catch(() => {});

      beacon("phase:create-bridge");
      const { createNativeBridge } = await import("./player/native");
      const bridge = createNativeBridge();
      bridge.attach(document.body);

      beacon("phase:load");
      await bridge.load({ url, startAtSec: 0 });
      await bridge.play();

      // Wait until it actually plays (or give up after 20s and report).
      let playing = false;
      const off = bridge.subscribe((s) => {
        if (s.status === "playing" && s.positionSec > 0.5) playing = true;
      });
      for (let i = 0; i < 40 && !playing; i++) await sleep(500);
      off();
      beacon(playing ? "phase:playing" : "phase:never-played");

      await sleep(5000); // play for a bit, like a user would

      // ---- the exit sequence that freezes on the phone ----
      beacon("phase:destroy");
      bridge.destroy(); // -> invoke stop -> native halt (pause + deferred occlude)
      beacon("phase:unlock");
      await invoke("plugin:native-player|unlock_orientation").catch(() => {});

      // Simulate the home screen's render storm right after exit.
      beacon("phase:rerender");
      const host = document.createElement("div");
      host.style.cssText = "position:fixed;inset:0;background:#0b0e14;overflow:auto;z-index:9999";
      document.body.appendChild(host);
      for (let i = 0; i < 400; i++) {
        const row = document.createElement("div");
        row.style.cssText = "padding:8px;border-bottom:1px solid #223;color:#9ab;font:14px sans-serif";
        row.textContent = `home row ${i} — the quick brown fox jumps over the lazy dog`;
        host.appendChild(row);
      }
      beacon("phase:rerender-done");

      // Keep beating; the workflow declares success only if native beats
      // continue well past this point.
      await sleep(12000);
      beacon("phase:survived");
    } catch (e) {
      beacon(`phase:error:${String(e).slice(0, 80)}`);
    }
  })();
}
