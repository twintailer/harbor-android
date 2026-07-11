function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

export function isWeb(): boolean {
  return typeof window !== "undefined" && !("__TAURI_INTERNALS__" in window);
}

export function isIOS(): boolean {
  if (typeof navigator === "undefined") return false;
  const ua = navigator.userAgent || "";
  if (/iPhone|iPad|iPod/i.test(ua)) return true;
  // iPadOS masquerades as desktop Safari ("Macintosh") but exposes touch.
  return /Macintosh/i.test(ua) && (navigator.maxTouchPoints ?? 0) > 1;
}

/** Running inside the Tauri shell on a mobile OS (iOS/Android). */
export function isMobileTauri(): boolean {
  try {
    // Debug escape hatch: preview the mobile shell in a desktop browser.
    if (typeof localStorage !== "undefined" && localStorage.getItem("harbor.forceMobileShell") === "1") {
      return true;
    }
  } catch {
    /* storage unavailable */
  }
  if (!isTauri()) return false;
  const ua = (navigator.userAgent || "").toLowerCase();
  return isIOS() || ua.includes("android");
}

export function isLinuxDesktop(): boolean {
  if (!isTauri()) return false;
  const ua = (navigator.userAgent || "").toLowerCase();
  const plat = (navigator.platform || "").toLowerCase();
  if (ua.includes("android")) return false;
  if (ua.includes("windows") || ua.includes("macintosh") || ua.includes("mac os")) return false;
  return ua.includes("linux") || plat.includes("linux");
}

export function isMacDesktop(): boolean {
  if (!isTauri()) return false;
  if (isIOS()) return false;
  const ua = (navigator.userAgent || "").toLowerCase();
  const plat = (navigator.platform || "").toLowerCase();
  return ua.includes("macintosh") || ua.includes("mac os") || plat.includes("mac");
}

export function isWindowsDesktop(): boolean {
  if (!isTauri()) return false;
  return (navigator.userAgent || "").toLowerCase().includes("windows");
}

export function isMobileDevice(): boolean {
  if (typeof navigator === "undefined" || typeof window === "undefined") return false;
  const ua = navigator.userAgent || "";
  if (/Android|webOS|iPhone|iPod|BlackBerry|IEMobile|Opera Mini|iPad/i.test(ua)) return true;
  if (/Macintosh/i.test(ua) && (navigator.maxTouchPoints ?? 0) > 1) return true;
  if ((navigator.maxTouchPoints ?? 0) > 0 && Math.min(window.innerWidth, window.innerHeight) < 640) {
    return true;
  }
  return false;
}
