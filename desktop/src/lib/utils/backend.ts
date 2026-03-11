// src/lib/utils/backend.ts
// Backend lifecycle utilities — wraps Tauri IPC commands with HTTP fallback.

import { isTauri } from "./platform";

/**
 * Restart the backend. In Tauri, uses the IPC command to respawn the sidecar.
 * In browser dev mode, attempts the HTTP endpoint as best-effort.
 */
export async function restartBackend(): Promise<void> {
  if (isTauri()) {
    const { invoke } = await import("@tauri-apps/api/core");
    await invoke("restart_backend");
  } else {
    // Browser dev mode fallback — best effort
    await fetch("http://127.0.0.1:9089/api/v1/system/restart", {
      method: "POST",
    }).catch(() => {});
  }
}
