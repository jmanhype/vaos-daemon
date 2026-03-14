// src/lib/stores/scheduledTasks.svelte.ts
// Scheduled Tasks store — Svelte 5 class with $state fields.
// Manages cron jobs via the Elixir scheduler endpoints, with mock fallback.

import { scheduler as schedulerApi } from "$lib/api/client";
import { connectSSE } from "$lib/api/sse";
import type {
  ScheduledRun,
  ScheduledRunStatus,
  CronPreset,
} from "$lib/api/types";
import type { StreamController } from "$lib/api/sse";

// ── Types ──────────────────────────────────────────────────────────────────────

export type ScheduledTaskStatus = "active" | "paused" | "failed";

export interface ScheduledTask {
  id: string;
  name: string;
  schedule: string;
  description: string;
  status: ScheduledTaskStatus;
  last_run: string | null;
  next_run: string | null;
  failure_count: number;
  last_error: string | null;
  created_at: string;
  updated_at: string;
  recent_runs?: ScheduledRun[];
}

export interface CreateScheduledTaskPayload {
  name: string;
  schedule: string;
  description?: string;
  task: string;
  agent_name?: string;
  timeout_minutes?: number;
}

// ── API response shapes ────────────────────────────────────────────────────────

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
  recent_runs?: ScheduledRun[];
}

interface JobsListResponse {
  jobs: BackendJob[];
}

interface JobResponse {
  job: BackendJob;
}

interface RunsResponse {
  runs: ScheduledRun[];
  total: number;
}

interface RunResponse {
  run: ScheduledRun;
}

interface PresetsResponse {
  presets: CronPreset[];
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
    recent_runs: job.recent_runs,
  };
}

// ── Mock data ────────────────────────────────────────────────────────────────

const MOCK_TASKS: ScheduledTask[] = [
  {
    id: "mock-1",
    name: "Daily Digest",
    schedule: "0 9 * * 1-5",
    description: "Summarize overnight activity each weekday morning.",
    status: "active",
    last_run: new Date(Date.now() - 23 * 3600000).toISOString(),
    next_run: new Date(Date.now() + 3600000).toISOString(),
    failure_count: 0,
    last_error: null,
    created_at: new Date(Date.now() - 30 * 86400000).toISOString(),
    updated_at: new Date(Date.now() - 23 * 3600000).toISOString(),
    recent_runs: [
      {
        id: "r1",
        scheduled_task_id: "mock-1",
        agent_name: "digest",
        status: "succeeded",
        trigger_type: "schedule",
        started_at: new Date(Date.now() - 23 * 3600000).toISOString(),
        duration_ms: 45000,
      },
      {
        id: "r2",
        scheduled_task_id: "mock-1",
        agent_name: "digest",
        status: "succeeded",
        trigger_type: "schedule",
        started_at: new Date(Date.now() - 47 * 3600000).toISOString(),
        duration_ms: 38000,
      },
    ],
  },
  {
    id: "mock-2",
    name: "Weekly Report",
    schedule: "0 8 * * 1",
    description: "Generate a weekly performance report.",
    status: "active",
    last_run: new Date(Date.now() - 168 * 3600000).toISOString(),
    next_run: new Date(Date.now() + 120 * 3600000).toISOString(),
    failure_count: 0,
    last_error: null,
    created_at: new Date(Date.now() - 60 * 86400000).toISOString(),
    updated_at: new Date(Date.now() - 168 * 3600000).toISOString(),
  },
  {
    id: "mock-3",
    name: "Dependency Audit",
    schedule: "0 2 * * 0",
    description: "Scan dependencies for vulnerabilities.",
    status: "paused",
    last_run: new Date(Date.now() - 14 * 86400000).toISOString(),
    next_run: null,
    failure_count: 0,
    last_error: null,
    created_at: new Date(Date.now() - 45 * 86400000).toISOString(),
    updated_at: new Date(Date.now() - 3 * 86400000).toISOString(),
  },
  {
    id: "mock-4",
    name: "Log Cleanup",
    schedule: "0 3 * * *",
    description: "Archive logs older than 7 days.",
    status: "failed",
    last_run: new Date(Date.now() - 48 * 3600000).toISOString(),
    next_run: new Date(Date.now() + 3 * 3600000).toISOString(),
    failure_count: 3,
    last_error: "Permission denied: /var/log/osa/archive",
    created_at: new Date(Date.now() - 20 * 86400000).toISOString(),
    updated_at: new Date(Date.now() - 48 * 3600000).toISOString(),
    recent_runs: [
      {
        id: "r5",
        scheduled_task_id: "mock-4",
        agent_name: "cleaner",
        status: "failed",
        trigger_type: "schedule",
        started_at: new Date(Date.now() - 48 * 3600000).toISOString(),
        duration_ms: 5000,
        error_message: "Permission denied",
      },
      {
        id: "r6",
        scheduled_task_id: "mock-4",
        agent_name: "cleaner",
        status: "succeeded",
        trigger_type: "schedule",
        started_at: new Date(Date.now() - 96 * 3600000).toISOString(),
        duration_ms: 32000,
      },
    ],
  },
];

const MOCK_PRESETS: CronPreset[] = [
  { id: "1m", cron: "* * * * *", label: "Every minute" },
  { id: "5m", cron: "*/5 * * * *", label: "Every 5 minutes" },
  { id: "15m", cron: "*/15 * * * *", label: "Every 15 minutes" },
  { id: "30m", cron: "*/30 * * * *", label: "Every 30 minutes" },
  { id: "1h", cron: "0 * * * *", label: "Every hour" },
  { id: "daily", cron: "0 9 * * *", label: "Daily at 9 AM" },
  { id: "weekly", cron: "0 9 * * 1", label: "Weekly on Monday" },
  { id: "monthly", cron: "0 9 1 * *", label: "Monthly on the 1st" },
];

const MOCK_RUNS: ScheduledRun[] = [
  {
    id: "r1",
    scheduled_task_id: "mock-1",
    agent_name: "digest",
    status: "succeeded",
    trigger_type: "schedule",
    started_at: new Date(Date.now() - 23 * 3600000).toISOString(),
    duration_ms: 45000,
    token_usage: { input: 1200, output: 850, cost_cents: 3 },
  },
  {
    id: "r5",
    scheduled_task_id: "mock-4",
    agent_name: "cleaner",
    status: "failed",
    trigger_type: "schedule",
    started_at: new Date(Date.now() - 48 * 3600000).toISOString(),
    duration_ms: 5000,
    error_message: "Permission denied",
  },
];

// ── Store ────────────────────────────────────────────────────────────────────

class ScheduledTasksStore {
  tasks = $state<ScheduledTask[]>([]);
  loading = $state(false);
  error = $state<string | null>(null);
  filterStatus = $state<string>("all");
  showForm = $state(false);
  editingId = $state<string | null>(null);

  presets = $state<CronPreset[]>([]);
  runs = $state<ScheduledRun[]>([]);
  runsTotal = $state(0);
  runsPage = $state(1);
  runsLoading = $state(false);
  runsFilter = $state<ScheduledRunStatus | "all">("all");
  activeRun = $state<ScheduledRun | null>(null);
  activeRunOutput = $state("");
  activeRunStreaming = $state(false);
  private _streamCtrl: StreamController | null = null;

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
  nextUpcoming = $derived(
    this.tasks
      .filter((t) => t.next_run !== null && t.status !== "paused")
      .sort(
        (a, b) =>
          new Date(a.next_run!).getTime() - new Date(b.next_run!).getTime(),
      )[0] ?? null,
  );
  filteredRuns = $derived(
    this.runsFilter === "all"
      ? this.runs
      : this.runs.filter((r) => r.status === this.runsFilter),
  );

  async fetchTasks(): Promise<void> {
    this.loading = true;
    this.error = null;
    try {
      const data = await schedulerApi.list<JobsListResponse>();
      this.tasks = (data.jobs ?? []).map(mapJob);
    } catch {
      this.tasks = [...MOCK_TASKS];
    } finally {
      this.loading = false;
    }
  }

  async fetchPresets(): Promise<void> {
    try {
      const data = await schedulerApi.presets<PresetsResponse>();
      this.presets = data.presets ?? [];
    } catch {
      this.presets = [...MOCK_PRESETS];
    }
  }

  async createTask(payload: CreateScheduledTaskPayload): Promise<void> {
    try {
      const data = await schedulerApi.create<JobResponse>(payload);
      this.tasks = [...this.tasks, mapJob(data.job)];
    } catch {
      this.tasks = [
        ...this.tasks,
        {
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
        },
      ];
    }
  }

  async pauseTask(id: string): Promise<void> {
    this._setStatus(id, "paused");
    try {
      const d = await schedulerApi.toggle<JobResponse>(id);
      this._replaceTask(mapJob(d.job));
    } catch {
      /* keep optimistic */
    }
  }

  async resumeTask(id: string): Promise<void> {
    this._setStatus(id, "active");
    try {
      const d = await schedulerApi.toggle<JobResponse>(id);
      this._replaceTask(mapJob(d.job));
    } catch {
      /* keep optimistic */
    }
  }

  async deleteTask(id: string): Promise<void> {
    const prev = this.tasks;
    this.tasks = this.tasks.filter((t) => t.id !== id);
    try {
      await schedulerApi.delete(id);
    } catch {
      this.tasks = prev;
    }
  }

  async triggerNow(id: string): Promise<ScheduledRun | null> {
    try {
      const data = await schedulerApi.runNow<RunResponse>(id);
      await this._refreshTask(id);
      return data.run;
    } catch {
      return null;
    }
  }

  async fetchRuns(_taskId?: string, page = 1): Promise<void> {
    this.runsLoading = true;
    this.runsPage = page;
    try {
      const data = await schedulerApi.runs<RunsResponse>(
        _taskId ?? "all",
        page,
      );
      this.runs = data.runs ?? [];
      this.runsTotal = data.total ?? 0;
    } catch {
      this.runs = [...MOCK_RUNS];
      this.runsTotal = MOCK_RUNS.length;
    } finally {
      this.runsLoading = false;
    }
  }

  async fetchRun(taskId: string, runId: string): Promise<void> {
    try {
      const data = await schedulerApi.run<RunResponse>(taskId, runId);
      this.activeRun = data.run;
      this.activeRunOutput = data.run.stdout ?? "";
    } catch {
      const mock = MOCK_RUNS.find((r) => r.id === runId);
      if (mock) {
        this.activeRun = mock;
        this.activeRunOutput = mock.stdout ?? "Mock output.\n";
      }
    }
  }

  streamRun(taskId: string, runId: string): void {
    this.stopStream();
    this.activeRunOutput = "";
    this.activeRunStreaming = true;
    this._streamCtrl = connectSSE(
      `/scheduler/jobs/${taskId}/runs/${runId}/stream`,
      {
        onEvent: (event) => {
          if (event.type === "streaming_token")
            this.activeRunOutput += event.delta;
          if (event.type === "done") {
            this.activeRunStreaming = false;
            this._refreshTask(taskId);
          }
        },
        onError: () => {
          this.activeRunStreaming = false;
        },
        onDone: () => {
          this.activeRunStreaming = false;
        },
      },
    );
  }

  stopStream(): void {
    this._streamCtrl?.abort();
    this._streamCtrl = null;
    this.activeRunStreaming = false;
  }
  closeRunDetail(): void {
    this.stopStream();
    this.activeRun = null;
    this.activeRunOutput = "";
  }
  setRunsFilter(filter: ScheduledRunStatus | "all"): void {
    this.runsFilter = filter;
  }
  setFilter(status: string): void {
    this.filterStatus = status;
  }
  toggleForm(): void {
    this.showForm = !this.showForm;
    if (!this.showForm) this.editingId = null;
  }
  setEditing(id: string | null): void {
    this.editingId = id;
    this.showForm = id !== null;
  }

  private _setStatus(id: string, status: ScheduledTaskStatus): void {
    this.tasks = this.tasks.map((t) =>
      t.id !== id
        ? t
        : {
            ...t,
            status,
            next_run: status === "paused" ? null : t.next_run,
            updated_at: new Date().toISOString(),
          },
    );
  }
  private _replaceTask(updated: ScheduledTask): void {
    this.tasks = this.tasks.map((t) => (t.id === updated.id ? updated : t));
  }
  private async _refreshTask(id: string): Promise<void> {
    try {
      const d = await schedulerApi.get<JobResponse>(id);
      this._replaceTask(mapJob(d.job));
    } catch {
      /* non-fatal */
    }
  }
}

export const scheduledTasksStore = new ScheduledTasksStore();
