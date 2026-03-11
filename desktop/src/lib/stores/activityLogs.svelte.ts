// src/lib/stores/activityLogs.svelte.ts
// Activity Logs page store — full log browsing with filtering, search,
// and API-backed fetching. Separate from activity.svelte.ts, which tracks
// real-time tool calls during an active stream session.

import type { ActivityLog, LogLevel, LogSource } from "$lib/mock-data";
import { generateMockActivityLogs } from "$lib/mock-data";
import { BASE_URL, API_PREFIX, getToken } from "$lib/api/client";

// ── Types ─────────────────────────────────────────────────────────────────────

type FilterLevel = LogLevel | "all";
type FilterSource = LogSource | "all";

// Shape of entries returned by GET /api/v1/analytics (best-effort mapping)
interface AnalyticsResponse {
  logs?: ActivityLog[];
  events?: ActivityLog[];
  [key: string]: unknown;
}

// Shape of entries returned by GET /api/v1/command-center/events/history
interface EventHistoryResponse {
  events?: ActivityLog[];
  history?: ActivityLog[];
  [key: string]: unknown;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function buildHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json",
  };
  const token = getToken();
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }
  return headers;
}

function matchesSearch(log: ActivityLog, query: string): boolean {
  if (!query) return true;
  const lower = query.toLowerCase();
  return (
    log.message.toLowerCase().includes(lower) ||
    log.source.toLowerCase().includes(lower) ||
    log.level.toLowerCase().includes(lower) ||
    (log.metadata !== undefined &&
      JSON.stringify(log.metadata).toLowerCase().includes(lower))
  );
}

// ── ActivityLogsStore Class ───────────────────────────────────────────────────

class ActivityLogsStore {
  // ── State ──────────────────────────────────────────────────────────────────

  logs = $state<ActivityLog[]>([]);
  loading = $state(false);
  error = $state<string | null>(null);

  filterLevel = $state<FilterLevel>("all");
  filterSource = $state<FilterSource>("all");
  searchQuery = $state("");

  // ── Derived ────────────────────────────────────────────────────────────────

  /** Logs with all active filters and search applied, newest-first. */
  filtered = $derived.by((): ActivityLog[] => {
    let result = this.logs;

    if (this.filterLevel !== "all") {
      const level = this.filterLevel;
      result = result.filter((log) => log.level === level);
    }

    if (this.filterSource !== "all") {
      const source = this.filterSource;
      result = result.filter((log) => log.source === source);
    }

    const q = this.searchQuery.trim();
    if (q) {
      result = result.filter((log) => matchesSearch(log, q));
    }

    return [...result].sort(
      (a, b) =>
        new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime(),
    );
  });

  /** Count of filtered results. */
  filteredCount = $derived(this.filtered.length);

  /** Total number of raw log entries held in state. */
  totalCount = $derived(this.logs.length);

  /** True when filters or search are narrowing the result set. */
  isFiltered = $derived(
    this.filterLevel !== "all" ||
      this.filterSource !== "all" ||
      this.searchQuery.trim() !== "",
  );

  // ── Fetch ──────────────────────────────────────────────────────────────────

  /**
   * Fetch logs from the backend. Tries three endpoints in order:
   *   1. GET /api/v1/command-center/events/history
   *   2. GET /api/v1/analytics
   * On any failure, falls back to MOCK_ACTIVITY_LOGS so the page always
   * has data to display.
   */
  async fetchLogs(): Promise<void> {
    this.loading = true;
    this.error = null;

    try {
      const logs = await this.#tryFetchFromApi();
      this.logs = logs;
    } catch (err) {
      this.error =
        err instanceof Error ? err.message : "Failed to fetch activity logs.";
      this.logs = generateMockActivityLogs();
    } finally {
      this.loading = false;
    }
  }

  // ── Mutations ──────────────────────────────────────────────────────────────

  /** Remove all log entries from state. */
  clearLogs(): void {
    this.logs = [];
  }

  /** Reset all active filters back to "all". */
  clearFilters(): void {
    this.filterLevel = "all";
    this.filterSource = "all";
    this.searchQuery = "";
  }

  /**
   * Apply a filter by dimension.
   * @param type - "level" or "source"
   * @param value - the filter value, or "all" to clear that dimension
   */
  setFilter(type: "level", value: FilterLevel): void;
  setFilter(type: "source", value: FilterSource): void;
  setFilter(type: "level" | "source", value: string): void {
    if (type === "level") {
      this.filterLevel = value as FilterLevel;
    } else {
      this.filterSource = value as FilterSource;
    }
  }

  /** Update the free-text search query. Pass an empty string to clear. */
  setSearch(query: string): void {
    this.searchQuery = query;
  }

  /**
   * Serialize the current filtered result set as a JSON string.
   * Suitable for writing to a file or copying to clipboard.
   */
  exportLogs(): string {
    return JSON.stringify(this.filtered, null, 2);
  }

  // ── Private ────────────────────────────────────────────────────────────────

  async #tryFetchFromApi(): Promise<ActivityLog[]> {
    const headers = buildHeaders();

    // Attempt 1: command-center event history
    try {
      const res = await fetch(
        `${BASE_URL}${API_PREFIX}/command-center/events/history`,
        { headers },
      );
      if (res.ok) {
        const data = (await res.json()) as EventHistoryResponse;
        const logs = data.events ?? data.history ?? [];
        if (logs.length > 0) return logs;
      }
    } catch {
      // Network error — fall through to next endpoint
    }

    // Attempt 2: analytics endpoint
    const res = await fetch(`${BASE_URL}${API_PREFIX}/analytics`, { headers });
    if (!res.ok) {
      throw new Error(`Analytics endpoint returned ${res.status}.`);
    }
    const data = (await res.json()) as AnalyticsResponse;
    const logs = data.logs ?? data.events ?? [];
    if (logs.length === 0) {
      throw new Error("No activity log data in analytics response.");
    }
    return logs;
  }
}

// ── Singleton Export ──────────────────────────────────────────────────────────

export const activityLogsStore = new ActivityLogsStore();
