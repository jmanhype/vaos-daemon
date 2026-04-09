// src/lib/stores/connection.svelte.ts
import { health } from "$api/client";
import type { HealthResponse } from "$api/types";

export type ConnectionStatus =
  | "connecting"
  | "connected"
  | "reconnecting"
  | "disconnected";

class ConnectionStore {
  status = $state<ConnectionStatus>("connecting");
  lastChecked = $state<Date | null>(null);
  lastConnectedAt = $state<Date | null>(null);
  error = $state<string | null>(null);
  health = $state<HealthResponse | null>(null);
  isChecking = $state(false);
  reconnectAttempts = $state(0);
  offlineQueueSize = $state(0);

  #pollInterval: ReturnType<typeof setInterval> | null = null;
  #reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  #pollMs: number = 10_000;
  #maxReconnectAttempts = 10;

  get isConnected(): boolean {
    return this.status === "connected";
  }
  get isReady(): boolean {
    return (
      this.status === "connected" &&
      (this.health?.status === "ok" || this.health?.status === "degraded")
    );
  }

  async check(): Promise<void> {
    if (this.isChecking) return;
    const wasConnected = this.status === "connected";
    this.isChecking = true;
    try {
      const data = await health.get();
      this.health = data;
      if (this.status !== "connected") {
        this.lastConnectedAt = new Date();
        if (this.status === "reconnecting") {
          this.reconnectAttempts = 0;
          await this.#syncOnReconnect();
        }
      }
      this.status = "connected";
      this.error = null;
    } catch (e) {
      this.health = null;
      if (wasConnected) this.#startReconnecting();
      else if (this.status !== "reconnecting") this.status = "disconnected";
      this.error = (e as Error).message;
    } finally {
      this.isChecking = false;
      this.lastChecked = new Date();
    }
  }

  startPolling(intervalMs: number = this.#pollMs): () => void {
    this.#pollMs = intervalMs;
    this.check();
    this.#pollInterval = setInterval(() => this.check(), intervalMs);
    return () => this.stopPolling();
  }

  stopPolling(): void {
    if (this.#pollInterval !== null) {
      clearInterval(this.#pollInterval);
      this.#pollInterval = null;
    }
    if (this.#reconnectTimer !== null) {
      clearTimeout(this.#reconnectTimer);
      this.#reconnectTimer = null;
    }
  }

  markCrashed(reason?: string): void {
    this.stopPolling();
    this.error = reason ?? "Backend crashed";
    this.health = null;
    this.#startReconnecting();
  }

  async onBackendReady(): Promise<void> {
    this.status = "connecting";
    this.error = null;
    await this.check();
    if (this.#pollInterval === null) this.startPolling(this.#pollMs);
  }

  updateQueueSize(size: number): void {
    this.offlineQueueSize = size;
  }

  #startReconnecting(): void {
    if (this.status === "reconnecting") return;
    this.status = "reconnecting";
    this.reconnectAttempts = 0;
    this.#attemptReconnect();
  }

  async #attemptReconnect(): Promise<void> {
    if (this.status !== "reconnecting") return;
    this.reconnectAttempts++;
    try {
      const data = await health.get();
      this.health = data;
      this.status = "connected";
      this.error = null;
      this.lastChecked = new Date();
      this.lastConnectedAt = new Date();
      this.reconnectAttempts = 0;
      await this.#syncOnReconnect();
      if (this.#pollInterval === null) this.startPolling(this.#pollMs);
      return;
    } catch {
      /* still offline */
    }
    if (this.reconnectAttempts >= this.#maxReconnectAttempts) {
      this.status = "disconnected";
      this.error = "Max reconnection attempts reached";
      return;
    }
    const delay = Math.min(1000 * 2 ** (this.reconnectAttempts - 1), 30_000);
    this.#reconnectTimer = setTimeout(() => this.#attemptReconnect(), delay);
  }

  async #syncOnReconnect(): Promise<void> {
    const { flushOfflineQueue, clearCache } = await import("$api/client");
    clearCache();
    const result = await flushOfflineQueue();
    this.offlineQueueSize = 0;
    if (result.failed > 0)
      this.error = `${result.failed} queued requests failed to sync`;
  }
}

export const connectionStore = new ConnectionStore();
