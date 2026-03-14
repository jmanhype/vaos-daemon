import type {
  Signal,
  SignalStats,
  SignalFilters,
  SignalPatterns,
} from "$lib/api/types";
import { BASE_URL, API_PREFIX, getToken } from "$lib/api/client";
import { connectSSE } from "$lib/api/sse";
import type { StreamController } from "$lib/api/sse";

// ── Helpers ───────────────────────────────────────────────────────────────────

function buildHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json",
  };
  const token = getToken();
  if (token) headers["Authorization"] = `Bearer ${token}`;
  return headers;
}

function buildQueryString(filters: SignalFilters): string {
  const params = new URLSearchParams();
  if (filters.mode) params.set("mode", filters.mode);
  if (filters.type) params.set("type", filters.type);
  if (filters.channel) params.set("channel", filters.channel);
  if (filters.weight_min !== undefined)
    params.set("weight_min", String(filters.weight_min));
  if (filters.weight_max !== undefined)
    params.set("weight_max", String(filters.weight_max));
  params.set("limit", "50");
  const qs = params.toString();
  return qs ? `?${qs}` : "";
}

// ── Store ─────────────────────────────────────────────────────────────────────

const MAX_LIVE_ITEMS = 100;

class SignalsStore {
  signals = $state<Signal[]>([]);
  stats = $state<SignalStats | null>(null);
  patterns = $state<SignalPatterns | null>(null);
  filters = $state<SignalFilters>({});
  loading = $state(false);
  error = $state<string | null>(null);
  liveFeed = $state<Signal[]>([]);
  liveConnected = $state(false);

  #sseController: StreamController | null = null;

  async fetchSignals(filters?: SignalFilters): Promise<void> {
    if (filters) this.filters = filters;
    this.loading = true;
    this.error = null;

    try {
      const qs = buildQueryString(this.filters);
      const res = await fetch(`${BASE_URL}${API_PREFIX}/signals${qs}`, {
        headers: buildHeaders(),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = (await res.json()) as { signals: Signal[]; total: number };
      this.signals = data.signals;
    } catch (err) {
      this.error =
        err instanceof Error ? err.message : "Failed to fetch signals.";
    } finally {
      this.loading = false;
    }
  }

  async fetchStats(): Promise<void> {
    try {
      const res = await fetch(`${BASE_URL}${API_PREFIX}/signals/stats`, {
        headers: buildHeaders(),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      this.stats = (await res.json()) as SignalStats;
    } catch {
      // Stats are non-critical — silently degrade
    }
  }

  async fetchPatterns(): Promise<void> {
    try {
      const res = await fetch(`${BASE_URL}${API_PREFIX}/signals/patterns`, {
        headers: buildHeaders(),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      this.patterns = (await res.json()) as SignalPatterns;
    } catch {
      // Patterns are non-critical
    }
  }

  subscribeLive(): void {
    if (this.#sseController) return;

    this.#sseController = connectSSE("/signals/live", {
      onEvent: (event) => {
        const raw = event as unknown as { type: string; data?: unknown };
        if (raw.type === "signal:new") {
          const signal = raw.data as Signal;
          this.liveFeed = [signal, ...this.liveFeed].slice(0, MAX_LIVE_ITEMS);
        }
        if (raw.type === "signal:stats_update") {
          this.stats = raw.data as SignalStats;
        }
      },
      onConnect: () => {
        this.liveConnected = true;
      },
      onDisconnect: () => {
        this.liveConnected = false;
      },
    });
  }

  unsubscribeLive(): void {
    this.#sseController?.abort();
    this.#sseController = null;
    this.liveConnected = false;
  }

  setFilter(
    key: keyof SignalFilters,
    value: string | number | undefined,
  ): void {
    this.filters = { ...this.filters, [key]: value || undefined };
  }

  clearFilters(): void {
    this.filters = {};
  }
}

export const signalsStore = new SignalsStore();
