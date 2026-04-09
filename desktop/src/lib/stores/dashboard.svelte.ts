// src/lib/stores/dashboard.svelte.ts
// Dashboard state with periodic refresh.

import { BASE_URL, API_PREFIX, getToken } from "$api/client";
import type {
  DashboardData,
  DashboardKpis,
  DashboardAgent,
  DashboardActivity,
  DashboardSystemHealth,
  DashboardAdaptation,
} from "$api/types";

const EMPTY_KPIS: DashboardKpis = {
  active_sessions: 0,
  agents_online: 0,
  agents_total: 0,
  signals_today: 0,
  tasks_completed: 0,
  tasks_pending: 0,
  tokens_used_today: 0,
  uptime_seconds: 0,
};

const EMPTY_HEALTH: DashboardSystemHealth = {
  backend: "ok",
  provider: null,
  provider_status: "disconnected",
  memory_mb: 0,
};

const EMPTY_ADAPTATION: DashboardAdaptation = {
  journal: {
    status: "inactive",
    signal_count: 0,
    in_flight_count: 0,
  },
  meta_state: {
    authority_domain: null,
    active_bottleneck: null,
    pivot_reason: null,
    active_steering_hypothesis: null,
    last_updated_at: null,
    last_experiment: null,
    recent_failed_count: 0,
    recent_failed_adaptations: [],
  },
  current_trial: null,
  active_promotions: [],
  active_suppressions: [],
  recent_signals: [],
};

async function fetchDashboard(): Promise<DashboardData> {
  const headers: Record<string, string> = { Accept: "application/json" };
  const token = getToken();
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await globalThis.fetch(`${BASE_URL}${API_PREFIX}/dashboard`, {
    headers,
  });

  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return (await res.json()) as DashboardData;
}

class DashboardStore {
  kpis = $state<DashboardKpis>(EMPTY_KPIS);
  activeAgents = $state<DashboardAgent[]>([]);
  recentActivity = $state<DashboardActivity[]>([]);
  systemHealth = $state<DashboardSystemHealth>(EMPTY_HEALTH);
  adaptation = $state<DashboardAdaptation>(EMPTY_ADAPTATION);
  loading = $state(true);
  error = $state<string | null>(null);
  lastUpdated = $state<Date | null>(null);

  #interval: ReturnType<typeof setInterval> | null = null;

  async load(): Promise<void> {
    try {
      const data = await fetchDashboard();
      this.kpis = data.kpis;
      this.activeAgents = data.active_agents;
      this.recentActivity = data.recent_activity;
      this.systemHealth = data.system_health;
      this.adaptation = data.adaptation ?? EMPTY_ADAPTATION;
      this.error = null;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
      this.lastUpdated = new Date();
    }
  }

  startAutoRefresh(intervalMs = 30_000): () => void {
    // Clear any pre-existing interval before starting a new one (guards against
    // double-mount in SPA navigation when the singleton is reused).
    this.stopAutoRefresh();
    // Reset loading so the skeleton renders on every re-visit.
    this.loading = true;
    this.load();
    this.#interval = setInterval(() => this.load(), intervalMs);
    return () => this.stopAutoRefresh();
  }

  stopAutoRefresh(): void {
    if (this.#interval !== null) {
      clearInterval(this.#interval);
      this.#interval = null;
    }
  }
}

export const dashboardStore = new DashboardStore();
