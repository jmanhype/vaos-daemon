// src/lib/stores/connection.svelte.ts
// Backend connection state with health check polling and auto-reconnect.

import { health } from "$api/client";
import type { HealthResponse } from "$api/types";

// ── Types ──────────────────────────────────────────────────────────────────────

export type ConnectionStatus = "connecting" | "connected" | "disconnected";

// ── Connection Store Class ────────────────────────────────────────────────────

class ConnectionStore {
  status = $state<ConnectionStatus>("connecting");
  lastChecked = $state<Date | null>(null);
  error = $state<string | null>(null);
  /** Full health payload from the last successful check */
  health = $state<HealthResponse | null>(null);
  isChecking = $state(false);

  // Private — polling interval handle
  #pollInterval: ReturnType<typeof setInterval> | null = null;
  #pollMs: number = 10_000;

  // ── Derived (computed getters, not $derived — class context) ────────────────

  get isConnected(): boolean {
    return this.status === "connected";
  }

  get isReady(): boolean {
    return (
      this.status === "connected" &&
      (this.health?.status === "ok" || this.health?.status === "degraded")
    );
  }

  // ── Public API ───────────────────────────────────────────────────────────────

  async check(): Promise<void> {
    if (this.isChecking) return;

    this.isChecking = true;
    try {
      const data = await health.get();
      this.health = data;
      this.status = "connected";
      this.error = null;
    } catch (e) {
      this.health = null;
      this.status = "disconnected";
      this.error = (e as Error).message;
    } finally {
      this.isChecking = false;
      this.lastChecked = new Date();
    }
  }

  /**
   * Start polling /health on the given interval (default 10 s).
   * Returns a cleanup function — call it in onDestroy.
   */
  startPolling(intervalMs: number = this.#pollMs): () => void {
    this.#pollMs = intervalMs;

    // Run immediately, then on interval
    this.check();

    this.#pollInterval = setInterval(() => {
      this.check();
    }, intervalMs);

    return () => this.stopPolling();
  }

  stopPolling(): void {
    if (this.#pollInterval !== null) {
      clearInterval(this.#pollInterval);
      this.#pollInterval = null;
    }
  }

  /**
   * React to a Tauri backend-crashed event.
   * Marks the connection as disconnected immediately without waiting for the
   * next poll cycle.
   */
  markCrashed(reason?: string): void {
    this.stopPolling();
    this.status = "disconnected";
    this.health = null;
    this.error = reason ?? "Backend crashed";
  }

  /**
   * Called when the Tauri backend-ready event fires.
   * Performs an immediate health check and restarts the poll loop.
   */
  async onBackendReady(): Promise<void> {
    this.status = "connecting";
    this.error = null;
    await this.check();
    if (this.#pollInterval === null) {
      this.startPolling(this.#pollMs);
    }
  }
}

// ── Singleton Export ──────────────────────────────────────────────────────────

export const connectionStore = new ConnectionStore();
