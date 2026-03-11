// src/lib/stores/scheduledTasks.svelte.ts
// Scheduled Tasks store — Svelte 5 class with $state fields.
// Manages cron jobs via the Elixir scheduler endpoints, with mock fallback.

import { scheduler as schedulerApi } from "$lib/api/client";

// ── Types ──────────────────────────────────────────────────────────────────────

export type ScheduledTaskStatus = "active" | "paused" | "failed";

export interface ScheduledTask {
  id: string;
  name: string;
  /** Cron expression, e.g. "0 9 * * 1-5" */
  schedule: string;
  /** Human-readable description of what the job does */
  description: string;
  status: ScheduledTaskStatus;
  /** ISO timestamp of the last successful run, null if never run */
  last_run: string | null;
  /** ISO timestamp of the next scheduled run, null if paused */
  next_run: string | null;
  /** Number of consecutive failures */
  failure_count: number;
  /** Last error message, null if last run succeeded */
  last_error: string | null;
  created_at: string;
  updated_at: string;
}

export interface CreateScheduledTaskPayload {
  name: string;
  schedule: string;
  description?: string;
  /** The task content / prompt to execute */
  task: string;
}

// ── API response shapes from the Elixir backend ───────────────────────────────

interface BackendJob {
  id: string;
  name: string;
  schedule: string;
  description?: string;
  enabled: boolean;
  last_run_at?: string | null;
  next_run_at?: string | null;
  failure_count?: number;
  last_error?: string | null;
  inserted_at: string;
  updated_at: string;
}

interface JobsListResponse {
  jobs: BackendJob[];
}

interface JobResponse {
  job: BackendJob;
}

// ── Backend → ScheduledTask mapping ──────────────────────────────────────────

function mapJob(job: BackendJob): ScheduledTask {
  let status: ScheduledTaskStatus;
  if (!job.enabled) {
    status = "paused";
  } else if ((job.failure_count ?? 0) > 0) {
    status = "failed";
  } else {
    status = "active";
  }

  return {
    id: job.id,
    name: job.name,
    schedule: job.schedule,
    description: job.description ?? "",
    status,
    last_run: job.last_run_at ?? null,
    next_run: job.next_run_at ?? null,
    failure_count: job.failure_count ?? 0,
    last_error: job.last_error ?? null,
    created_at: job.inserted_at,
    updated_at: job.updated_at,
  };
}

// ── Mock data (used when the backend is unreachable) ─────────────────────────

const MOCK_TASKS: ScheduledTask[] = [
  {
    id: "mock-1",
    name: "Daily Digest",
    schedule: "0 9 * * 1-5",
    description:
      "Summarize overnight activity and surface priority items each weekday morning.",
    status: "active",
    last_run: new Date(Date.now() - 23 * 60 * 60 * 1000).toISOString(),
    next_run: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
    failure_count: 0,
    last_error: null,
    created_at: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString(),
    updated_at: new Date(Date.now() - 23 * 60 * 60 * 1000).toISOString(),
  },
  {
    id: "mock-2",
    name: "Weekly Report",
    schedule: "0 8 * * 1",
    description:
      "Generate a weekly performance report and send to the configured channel.",
    status: "active",
    last_run: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString(),
    next_run: new Date(Date.now() + 5 * 24 * 60 * 60 * 1000).toISOString(),
    failure_count: 0,
    last_error: null,
    created_at: new Date(Date.now() - 60 * 24 * 60 * 60 * 1000).toISOString(),
    updated_at: new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString(),
  },
  {
    id: "mock-3",
    name: "Dependency Audit",
    schedule: "0 2 * * 0",
    description:
      "Scan project dependencies for known vulnerabilities and open a report.",
    status: "paused",
    last_run: new Date(Date.now() - 14 * 24 * 60 * 60 * 1000).toISOString(),
    next_run: null,
    failure_count: 0,
    last_error: null,
    created_at: new Date(Date.now() - 45 * 24 * 60 * 60 * 1000).toISOString(),
    updated_at: new Date(Date.now() - 3 * 24 * 60 * 60 * 1000).toISOString(),
  },
  {
    id: "mock-4",
    name: "Log Cleanup",
    schedule: "0 3 * * *",
    description:
      "Archive and compress logs older than 7 days to reduce disk usage.",
    status: "failed",
    last_run: new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString(),
    next_run: new Date(Date.now() + 3 * 60 * 60 * 1000).toISOString(),
    failure_count: 3,
    last_error: "Permission denied: /var/log/osa/archive",
    created_at: new Date(Date.now() - 20 * 24 * 60 * 60 * 1000).toISOString(),
    updated_at: new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString(),
  },
];

// ── ScheduledTasksStore Class ──────────────────────────────────────────────────

class ScheduledTasksStore {
  tasks = $state<ScheduledTask[]>([]);
  loading = $state(false);
  error = $state<string | null>(null);
  filterStatus = $state<string>("all");
  showForm = $state(false);
  editingId = $state<string | null>(null);

  // ── Derived ──────────────────────────────────────────────────────────────────

  filtered = $derived(
    this.filterStatus === "all"
      ? this.tasks
      : this.tasks.filter((t) => t.status === this.filterStatus),
  );

  activeCount = $derived(
    this.tasks.filter((t) => t.status === "active").length,
  );

  pausedCount = $derived(
    this.tasks.filter((t) => t.status === "paused").length,
  );

  failedCount = $derived(
    this.tasks.filter((t) => t.status === "failed").length,
  );

  /** The task with the soonest next_run that is not paused */
  nextUpcoming = $derived(
    this.tasks
      .filter((t) => t.next_run !== null && t.status !== "paused")
      .sort((a, b) => {
        const ta = new Date(a.next_run!).getTime();
        const tb = new Date(b.next_run!).getTime();
        return ta - tb;
      })[0] ?? null,
  );

  // ── Actions ──────────────────────────────────────────────────────────────────

  async fetchTasks(): Promise<void> {
    this.loading = true;
    this.error = null;
    try {
      const data = await schedulerApi.list<JobsListResponse>();
      this.tasks = (data.jobs ?? []).map(mapJob);
    } catch {
      // Backend unreachable — use mock data so the UI is usable during dev
      this.tasks = [...MOCK_TASKS];
    } finally {
      this.loading = false;
    }
  }

  async createTask(payload: CreateScheduledTaskPayload): Promise<void> {
    try {
      const data = await schedulerApi.create<JobResponse>(payload);
      this.tasks = [...this.tasks, mapJob(data.job)];
    } catch {
      // Fall back to a local-only optimistic insert with a temporary id
      const optimistic: ScheduledTask = {
        id: `local-${crypto.randomUUID()}`,
        name: payload.name,
        schedule: payload.schedule,
        description: payload.description ?? "",
        status: "active",
        last_run: null,
        next_run: null,
        failure_count: 0,
        last_error: null,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
      this.tasks = [...this.tasks, optimistic];
    }
  }

  async pauseTask(id: string): Promise<void> {
    // Optimistic update
    this._setStatus(id, "paused");
    try {
      const data = await schedulerApi.toggle<JobResponse>(id);
      this._replaceTask(mapJob(data.job));
    } catch {
      // Keep the optimistic state — the local mutation is the fallback
    }
  }

  async resumeTask(id: string): Promise<void> {
    // Optimistic update
    this._setStatus(id, "active");
    try {
      const data = await schedulerApi.toggle<JobResponse>(id);
      this._replaceTask(mapJob(data.job));
    } catch {
      // Keep the optimistic state
    }
  }

  async deleteTask(id: string): Promise<void> {
    // Optimistic removal
    const previous = this.tasks;
    this.tasks = this.tasks.filter((t) => t.id !== id);
    try {
      await schedulerApi.delete(id);
    } catch {
      // Rollback on failure
      this.tasks = previous;
    }
  }

  async runNow(id: string): Promise<void> {
    try {
      await schedulerApi.runNow(id);
      // Refresh the task to pick up the updated last_run timestamp
      await this._refreshTask(id);
    } catch {
      // Non-fatal — surface via the global error only if needed by the caller
    }
  }

  // ── UI state helpers ─────────────────────────────────────────────────────────

  setFilter(status: string): void {
    this.filterStatus = status;
  }

  toggleForm(): void {
    this.showForm = !this.showForm;
    if (!this.showForm) {
      this.editingId = null;
    }
  }

  setEditing(id: string | null): void {
    this.editingId = id;
    this.showForm = id !== null;
  }

  // ── Private helpers ──────────────────────────────────────────────────────────

  private _setStatus(id: string, status: ScheduledTaskStatus): void {
    this.tasks = this.tasks.map((t) => {
      if (t.id !== id) return t;
      return {
        ...t,
        status,
        // Clear next_run when pausing so derived nextUpcoming excludes it
        next_run: status === "paused" ? null : t.next_run,
        updated_at: new Date().toISOString(),
      };
    });
  }

  private _replaceTask(updated: ScheduledTask): void {
    this.tasks = this.tasks.map((t) => (t.id === updated.id ? updated : t));
  }

  private async _refreshTask(id: string): Promise<void> {
    try {
      const data = await schedulerApi.get<JobResponse>(id);
      this._replaceTask(mapJob(data.job));
    } catch {
      // Non-fatal
    }
  }
}

// ── Singleton Export ──────────────────────────────────────────────────────────

export const scheduledTasksStore = new ScheduledTasksStore();
