// src/lib/mock-data.ts
// Shared mock data and types for pages that degrade gracefully when the
// backend is unavailable. Components should prefer live API data and fall
// back to these fixtures only on fetch failure.
//
// All generators return fresh data relative to Date.now() on each call.
// Use crypto.randomUUID() for IDs so repeated calls produce unique entries.

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type LogLevel = "debug" | "info" | "warn" | "error";

// 'session', 'tool', and 'command-center' are legacy values used by existing
// ActivityFilters and ActivityTable components. New mock data uses the narrower
// core set but the type must remain a superset so existing components compile
// without modification.
export type LogSource =
  | "agent"
  | "system"
  | "user"
  | "api"
  | "session"
  | "tool"
  | "command-center";

export interface ActivityLog {
  /** Unique log entry identifier */
  id: string;
  /** ISO 8601 timestamp */
  timestamp: string;
  /** Severity level */
  level: LogLevel;
  /** Subsystem that emitted this log */
  source: LogSource;
  /** Human-readable description of the event */
  message: string;
  /** Optional structured metadata (tool name, session id, etc.) */
  metadata?: Record<string, unknown>;
}

export interface UsageStats {
  totalMessages: number;
  totalSessions: number;
  totalTokens: number;
  /** Average response time in milliseconds */
  avgResponseTime: number;
  dailyUsage: { date: string; messages: number; tokens: number }[];
  modelUsage: { model: string; count: number; tokens: number }[];
}

export interface MemoryEntry {
  id: string;
  key: string;
  value: string;
  category: "fact" | "preference" | "context" | "instruction";
  created_at: string;
  updated_at: string;
  source: "user" | "agent" | "system";
  /** 0.0–1.0 relevance score used by the compactor */
  relevance: number;
}

export interface ScheduledTask {
  id: string;
  name: string;
  description: string;
  /** Cron expression */
  schedule: string;
  command: string;
  status: "active" | "paused" | "completed" | "failed";
  last_run: string | null;
  next_run: string | null;
  created_at: string;
  run_count: number;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function msAgo(now: number, ms: number): string {
  return new Date(now - ms).toISOString();
}

const H = (h: number): number => h * 60 * 60 * 1000;
const M = (m: number): number => m * 60 * 1000;
const D = (d: number): number => d * H(24);

function dateStr(now: number, daysAgo: number): string {
  return new Date(now - D(daysAgo)).toISOString().slice(0, 10);
}

// ---------------------------------------------------------------------------
// 1. generateMockActivityLogs
// ---------------------------------------------------------------------------
// 30 entries spanning the last 24 hours.
// Mix: ~60% info, ~15% warn, ~10% error, ~15% debug.

export function generateMockActivityLogs(): ActivityLog[] {
  const now = Date.now();

  type Row = [
    number, // offset ms into the past
    LogLevel,
    LogSource,
    string, // message
    Record<string, unknown>?,
  ];

  const rows: Row[] = [
    // 0–30 min ago
    [
      M(3),
      "info",
      "agent",
      "Agent MasterOrchestrator dispatched task to CodeReviewer",
      { task_id: "task-8821", target: "CodeReviewer" },
    ],
    [
      M(9),
      "debug",
      "system",
      "SSE heartbeat sent for session f3a9c1",
      { session_id: "f3a9c1", latency_ms: 3 },
    ],
    [
      M(17),
      "info",
      "api",
      "Model switched to claude-sonnet-4-20250514",
      { previous: "claude-opus-4-20250514", reason: "cost_optimization" },
    ],
    [
      M(24),
      "info",
      "agent",
      "Tool execution: file_read completed in 42ms",
      { tool: "file_read", duration_ms: 42, path: "/src/lib/stores/agent.ts" },
    ],
    [
      M(31),
      "warn",
      "system",
      "Token budget at 85% — compactor triggered",
      { usage_pct: 85, session_id: "f3a9c1" },
    ],

    // 30 min – 2 h ago
    [
      M(44),
      "info",
      "agent",
      "Memory stored: project architecture decision",
      { category: "context", key: "arch_decision_2026_03" },
    ],
    [
      M(57),
      "debug",
      "agent",
      "Subagent CodeReviewer returned result in 3.2s",
      { agent: "CodeReviewer", duration_ms: 3200, status: "success" },
    ],
    [
      H(1),
      "info",
      "system",
      "SSE stream connected for session abc123",
      { session_id: "abc123", transport: "sse" },
    ],
    [
      H(1) + M(12),
      "info",
      "agent",
      "Swarm launched: debug pattern with 3 agents",
      {
        pattern: "debug",
        agents: ["Debugger", "TestAutomator", "CodeReviewer"],
        swarm_id: "swarm-441",
      },
    ],
    [
      H(1) + M(28),
      "error",
      "api",
      "Request to /api/tool_call timed out after 30s",
      { endpoint: "/api/tool_call", timeout_ms: 30000, tool: "bash_exec" },
    ],
    [
      H(1) + M(45),
      "info",
      "agent",
      'Scheduler job "log-rotation" executed successfully',
      { job: "log-rotation", duration_ms: 188 },
    ],
    [
      H(1) + M(58),
      "warn",
      "agent",
      "Agent PerformanceOptimizer exceeded expected token allocation",
      { agent: "PerformanceOptimizer", allocated: 125000, used: 148200 },
    ],

    // 2–6 h ago
    [
      H(2) + M(15),
      "info",
      "user",
      "Session started: user initiated new conversation",
      { session_id: "abc123" },
    ],
    [
      H(2) + M(44),
      "debug",
      "system",
      "Context compaction triggered at 91% utilization",
      { utilization_pct: 91, tokens_before: 910000, tokens_after: 320000 },
    ],
    [
      H(3) + M(8),
      "info",
      "agent",
      "Tool execution: bash_exec completed in 215ms",
      { tool: "bash_exec", duration_ms: 215, exit_code: 0 },
    ],
    [
      H(3) + M(52),
      "error",
      "agent",
      "Agent SecurityAuditor terminated: unhandled exception in hook",
      { agent: "SecurityAuditor", error: "RuntimeError", hook: "PostToolUse" },
    ],
    [
      H(4) + M(3),
      "info",
      "system",
      "Agent SecurityAuditor restarted by supervisor",
      { agent: "SecurityAuditor", restart_count: 1 },
    ],
    [
      H(4) + M(29),
      "info",
      "agent",
      "Pattern saved: Svelte 5 runes migration workflow",
      { category: "pattern", key: "svelte5_runes_migration" },
    ],
    [
      H(5) + M(11),
      "debug",
      "api",
      "Streaming response initiated: 1247 tokens buffered",
      { session_id: "de77f2", tokens: 1247 },
    ],
    [
      H(5) + M(38),
      "warn",
      "system",
      "Disk usage for agent state snapshots at 78%",
      { path: "~/.claude/work/", usage_pct: 78 },
    ],

    // 6–12 h ago
    [
      H(6) + M(20),
      "info",
      "agent",
      "MasterOrchestrator spawned batch: 5 agents for full-stack swarm",
      { batch_id: "batch-092", agents: 5, pattern: "full-stack" },
    ],
    [
      H(7) + M(45),
      "info",
      "agent",
      "Tool execution: grep completed in 8ms",
      { tool: "grep", duration_ms: 8, matches: 14 },
    ],
    [
      H(8) + M(12),
      "error",
      "api",
      "Anthropic API rate limit reached — backoff 60s",
      { status: 429, retry_after_ms: 60000 },
    ],
    [
      H(9),
      "info",
      "system",
      "Health check passed: all OTP supervisors nominal",
      { supervisors: 7, status: "healthy" },
    ],
    [
      H(10) + M(33),
      "debug",
      "agent",
      "Episodic memory entry written for session abc123",
      { session_id: "abc123", entry_id: "ep-7712" },
    ],

    // 12–24 h ago
    [
      H(12) + M(5),
      "info",
      "user",
      "User updated preferred model to claude-opus-4-20250514",
      { model: "claude-opus-4-20250514" },
    ],
    [
      H(14) + M(49),
      "warn",
      "system",
      "Session de77f2 idle for 30 minutes — marked for pruning",
      { session_id: "de77f2", idle_ms: 1800000 },
    ],
    [
      H(16) + M(22),
      "info",
      "agent",
      "Analytics aggregation job completed: 30-day rollup written",
      { job: "analytics-aggregation", records: 8940 },
    ],
    [
      H(19),
      "debug",
      "system",
      "Model cache cleaned: 3 stale entries removed",
      { removed: 3, cache_size_after: 12 },
    ],
    [
      H(22) + M(14),
      "info",
      "agent",
      "Agent state backup completed: 2.1 MB written to disk",
      { size_bytes: 2202009, path: "~/.claude/work/state-backup.json" },
    ],
    [
      H(23) + M(50),
      "info",
      "system",
      "OSA desktop started — Tauri runtime v2.1.0",
      { version: "2.1.0", platform: "darwin" },
    ],
  ];

  return rows.map(([offset, level, source, message, metadata]) => ({
    id: crypto.randomUUID(),
    timestamp: msAgo(now, offset),
    level,
    source,
    message,
    ...(metadata !== undefined ? { metadata } : {}),
  }));
}

// ---------------------------------------------------------------------------
// 2. generateMockUsageStats
// ---------------------------------------------------------------------------
// 30 days of daily usage. Models: opus (~30%), sonnet (~55%), haiku (~15%).

export function generateMockUsageStats(): UsageStats {
  const now = Date.now();

  let totalMessages = 0;
  let totalTokens = 0;

  const dailyUsage: UsageStats["dailyUsage"] = [];

  for (let d = 29; d >= 0; d--) {
    const dow = new Date(now - D(d)).getDay();
    const isWeekend = dow === 0 || dow === 6;
    // Deterministic-ish variance using day index and a sine curve
    const base = isWeekend ? 18 : 52;
    const wave = Math.round(Math.sin(d * 0.71) * (isWeekend ? 8 : 22));
    const messages = Math.max(4, base + wave);
    const tokens = messages * (1700 + ((d * 137) % 1300));

    totalMessages += messages;
    totalTokens += tokens;

    dailyUsage.push({ date: dateStr(now, d), messages, tokens });
  }

  const modelUsage: UsageStats["modelUsage"] = [
    {
      model: "claude-sonnet-4-20250514",
      count: Math.round(totalMessages * 0.55),
      tokens: Math.round(totalTokens * 0.52),
    },
    {
      model: "claude-opus-4-20250514",
      count: Math.round(totalMessages * 0.3),
      tokens: Math.round(totalTokens * 0.4),
    },
    {
      model: "claude-haiku-4-5-20251001",
      count: Math.round(totalMessages * 0.15),
      tokens: Math.round(totalTokens * 0.08),
    },
  ];

  return {
    totalMessages,
    totalSessions: Math.round(totalMessages / 12),
    totalTokens,
    avgResponseTime: 2340,
    dailyUsage,
    modelUsage,
  };
}

// ---------------------------------------------------------------------------
// 3. generateMockMemoryEntries
// ---------------------------------------------------------------------------
// 20 OSA-specific memory entries.

export function generateMockMemoryEntries(): MemoryEntry[] {
  const now = Date.now();

  type Row = {
    key: string;
    value: string;
    category: MemoryEntry["category"];
    source: MemoryEntry["source"];
    createdDaysAgo: number;
    updatedDaysAgo: number;
    relevance: number;
  };

  const rows: Row[] = [
    {
      key: "preferred_model",
      value: "claude-sonnet-4-20250514",
      category: "preference",
      source: "user",
      createdDaysAgo: 14,
      updatedDaysAgo: 2,
      relevance: 0.97,
    },
    {
      key: "project_root",
      value: "/Users/dev/myapp",
      category: "fact",
      source: "user",
      createdDaysAgo: 30,
      updatedDaysAgo: 30,
      relevance: 0.95,
    },
    {
      key: "test_framework",
      value: "vitest",
      category: "fact",
      source: "agent",
      createdDaysAgo: 28,
      updatedDaysAgo: 28,
      relevance: 0.91,
    },
    {
      key: "always_run_tests_before_commit",
      value: "true",
      category: "instruction",
      source: "user",
      createdDaysAgo: 25,
      updatedDaysAgo: 25,
      relevance: 0.99,
    },
    {
      key: "arch_decision_2026_03",
      value:
        "Use SvelteKit SSR with adapter-node. SSG ruled out due to user-specific data requirements.",
      category: "context",
      source: "agent",
      createdDaysAgo: 7,
      updatedDaysAgo: 7,
      relevance: 0.88,
    },
    {
      key: "code_style_explicit_types",
      value:
        "Always use explicit TypeScript return types on public functions. No implicit any.",
      category: "instruction",
      source: "user",
      createdDaysAgo: 20,
      updatedDaysAgo: 20,
      relevance: 0.93,
    },
    {
      key: "package_manager",
      value: "npm",
      category: "fact",
      source: "agent",
      createdDaysAgo: 29,
      updatedDaysAgo: 29,
      relevance: 0.82,
    },
    {
      key: "svelte5_runes_migration",
      value:
        "Replace export let with $props(), $: with $derived/$effect, on:click with onclick, slot with {@render children()}.",
      category: "context",
      source: "agent",
      createdDaysAgo: 5,
      updatedDaysAgo: 5,
      relevance: 0.86,
    },
    {
      key: "preferred_commit_style",
      value:
        "Conventional commits. Scope required. No AI co-author lines. Present tense imperative.",
      category: "instruction",
      source: "user",
      createdDaysAgo: 18,
      updatedDaysAgo: 18,
      relevance: 0.96,
    },
    {
      key: "database_orm",
      value:
        "Drizzle ORM with PostgreSQL. Never use raw string interpolation in queries.",
      category: "fact",
      source: "user",
      createdDaysAgo: 22,
      updatedDaysAgo: 10,
      relevance: 0.89,
    },
    {
      key: "token_budget_warn_threshold",
      value: "850000",
      category: "preference",
      source: "system",
      createdDaysAgo: 30,
      updatedDaysAgo: 30,
      relevance: 0.78,
    },
    {
      key: "primary_language",
      value: "TypeScript",
      category: "fact",
      source: "agent",
      createdDaysAgo: 30,
      updatedDaysAgo: 30,
      relevance: 0.85,
    },
    {
      key: "ui_component_library",
      value: "shadcn-svelte with Tailwind CSS. Custom theme tokens in app.css.",
      category: "fact",
      source: "user",
      createdDaysAgo: 15,
      updatedDaysAgo: 15,
      relevance: 0.84,
    },
    {
      key: "error_handling_pattern",
      value:
        "Use Result<T, E> for expected errors. Reserve try/catch for unexpected runtime errors only.",
      category: "instruction",
      source: "user",
      createdDaysAgo: 17,
      updatedDaysAgo: 17,
      relevance: 0.9,
    },
    {
      key: "ci_provider",
      value: "GitHub Actions. Workflow at .github/workflows/ci.yml.",
      category: "fact",
      source: "agent",
      createdDaysAgo: 26,
      updatedDaysAgo: 26,
      relevance: 0.76,
    },
    {
      key: "agent_max_parallel",
      value: "10",
      category: "preference",
      source: "system",
      createdDaysAgo: 30,
      updatedDaysAgo: 30,
      relevance: 0.74,
    },
    {
      key: "session_abc123_context",
      value:
        "Working on BusinessOS SvelteKit frontend. Focus: dashboard activity feed and mock data layer.",
      category: "context",
      source: "agent",
      createdDaysAgo: 0,
      updatedDaysAgo: 0,
      relevance: 0.98,
    },
    {
      key: "backend_runtime",
      value: "Elixir/OTP 27 with Phoenix 1.7. BEAM VM.",
      category: "fact",
      source: "user",
      createdDaysAgo: 30,
      updatedDaysAgo: 30,
      relevance: 0.8,
    },
    {
      key: "no_emojis_in_output",
      value: "true",
      category: "instruction",
      source: "user",
      createdDaysAgo: 12,
      updatedDaysAgo: 12,
      relevance: 0.99,
    },
    {
      key: "memory_compaction_schedule",
      value:
        "Daily at 03:00 local time. Retain entries with relevance >= 0.70.",
      category: "preference",
      source: "system",
      createdDaysAgo: 14,
      updatedDaysAgo: 14,
      relevance: 0.72,
    },
  ];

  return rows.map((r) => ({
    id: crypto.randomUUID(),
    key: r.key,
    value: r.value,
    category: r.category,
    source: r.source,
    created_at: msAgo(now, D(r.createdDaysAgo)),
    updated_at: msAgo(now, D(r.updatedDaysAgo)),
    relevance: r.relevance,
  }));
}

// ---------------------------------------------------------------------------
// 4. generateMockScheduledTasks
// ---------------------------------------------------------------------------
// 8 OSA-relevant cron tasks.

export function generateMockScheduledTasks(): ScheduledTask[] {
  const now = Date.now();

  type Row = {
    name: string;
    description: string;
    schedule: string;
    command: string;
    status: ScheduledTask["status"];
    lastRunMs: number | null; // ms ago (positive = past)
    nextRunMs: number | null; // ms from now (negative = future)
    createdDaysAgo: number;
    runCount: number;
  };

  const rows: Row[] = [
    {
      name: "Memory Compaction",
      description:
        "Consolidate and prune low-relevance memory entries. Retains entries with relevance >= 0.70.",
      schedule: "0 3 * * *",
      command: "osa memory compact --threshold 0.70 --dry-run false",
      status: "active",
      lastRunMs: H(21),
      nextRunMs: H(3),
      createdDaysAgo: 30,
      runCount: 29,
    },
    {
      name: "Token Budget Reset",
      description:
        "Reset per-session token counters and flush stale budget allocations at midnight.",
      schedule: "0 0 * * *",
      command: "osa budget reset --scope sessions --flush-stale true",
      status: "active",
      lastRunMs: H(18),
      nextRunMs: H(6),
      createdDaysAgo: 30,
      runCount: 30,
    },
    {
      name: "Log Rotation",
      description:
        "Rotate and compress agent activity logs older than 7 days. Archive to ~/.claude/logs/archive/.",
      schedule: "30 2 * * *",
      command:
        "osa logs rotate --max-age 7d --compress gzip --archive ~/.claude/logs/archive/",
      status: "active",
      lastRunMs: H(21) + M(30),
      nextRunMs: H(2) + M(30),
      createdDaysAgo: 28,
      runCount: 27,
    },
    {
      name: "Health Check",
      description:
        "Verify all OTP supervisors, SSE connections, and downstream API availability.",
      schedule: "*/15 * * * *",
      command: "osa health check --supervisors --sse --api anthropic",
      status: "active",
      lastRunMs: M(4),
      nextRunMs: M(11),
      createdDaysAgo: 25,
      runCount: 2391,
    },
    {
      name: "Model Cache Cleanup",
      description:
        "Remove stale model response cache entries older than 24 hours.",
      schedule: "0 4 * * *",
      command: "osa cache clean --target model --max-age 24h",
      status: "active",
      lastRunMs: H(20),
      nextRunMs: H(4),
      createdDaysAgo: 22,
      runCount: 21,
    },
    {
      name: "Analytics Aggregation",
      description:
        "Aggregate daily usage metrics (messages, tokens, latency) into a 30-day rollup.",
      schedule: "0 1 * * *",
      command:
        "osa analytics aggregate --window 30d --output ~/.claude/work/analytics-rollup.json",
      status: "active",
      lastRunMs: H(17),
      nextRunMs: H(7),
      createdDaysAgo: 20,
      runCount: 20,
    },
    {
      name: "Session Pruning",
      description:
        "Terminate sessions idle for more than 2 hours and release their memory allocations.",
      schedule: "0 */2 * * *",
      command: "osa sessions prune --idle-threshold 2h --release-memory true",
      status: "paused",
      lastRunMs: H(14),
      nextRunMs: null,
      createdDaysAgo: 18,
      runCount: 97,
    },
    {
      name: "Backup Agent State",
      description:
        "Snapshot current agent state, memory store, and scheduler registry to disk.",
      schedule: "0 */6 * * *",
      command:
        "osa state backup --output ~/.claude/work/state-backup.json --compress true",
      status: "failed",
      lastRunMs: H(5),
      nextRunMs: H(1),
      createdDaysAgo: 30,
      runCount: 118,
    },
  ];

  return rows.map((r) => ({
    id: crypto.randomUUID(),
    name: r.name,
    description: r.description,
    schedule: r.schedule,
    command: r.command,
    status: r.status,
    last_run: r.lastRunMs !== null ? msAgo(now, r.lastRunMs) : null,
    next_run:
      r.nextRunMs !== null ? new Date(now + r.nextRunMs).toISOString() : null,
    created_at: msAgo(now, D(r.createdDaysAgo)),
    run_count: r.runCount,
  }));
}
