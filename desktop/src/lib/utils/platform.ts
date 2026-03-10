/**
 * Platform detection utilities for Tauri + browser environments.
 * All functions are safe to call in SSR/SSG contexts (they return false
 * when `window` is unavailable).
 */

/**
 * Returns true when running inside a Tauri WebView.
 * Tauri injects `window.__TAURI_INTERNALS__` into the WebView context.
 */
export function isTauri(): boolean {
  if (typeof window === "undefined") return false;
  return Boolean(
    (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__,
  );
}

/**
 * Returns true when running on macOS.
 * Reads `navigator.platform` — sufficient for layout decisions without
 * the plugin-os overhead at startup.
 */
export function isMacOS(): boolean {
  if (typeof navigator === "undefined") return false;
  return navigator.platform.toLowerCase().includes("mac");
}

/**
 * Returns true when running on Windows.
 */
export function isWindows(): boolean {
  if (typeof navigator === "undefined") return false;
  return navigator.platform.toLowerCase().includes("win");
}

/**
 * Returns true when running on Linux.
 */
export function isLinux(): boolean {
  if (typeof navigator === "undefined") return false;
  const p = navigator.platform.toLowerCase();
  return p.includes("linux") || p.includes("x11");
}
