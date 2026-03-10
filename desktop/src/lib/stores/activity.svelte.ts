// src/lib/stores/activity.svelte.ts
// Activity feed store — tracks tool calls as they arrive via SSE events.
// Drives the ActivityFeed component with live tool status and elapsed time.

import type {
  StreamEvent,
  ToolCallEvent,
  ToolResultEvent,
} from "$lib/api/types";

// ── Types ─────────────────────────────────────────────────────────────────────

export type VerbosityLevel = "off" | "new" | "all" | "verbose";

export interface Activity {
  /** Maps to the SSE tool_use_id */
  id: string;
  /** Raw tool name, e.g. "bash", "read_file", "write_file" */
  tool: string;
  /** Human-readable label shown in the feed */
  label: string;
  /** Brief argument / path summary (first path or truncated input) */
  summary: string;
  /** Emoji prefix matching the TUI pattern */
  emoji: string;
  /** Epoch ms when the tool call began */
  startedAt: number;
  /** Epoch ms when the result arrived, or null if still running */
  finishedAt: number | null;
  /** Whether the result was an error */
  isError: boolean;
}

// ── Tool emoji / label map (matches TUI conventions) ─────────────────────────

const TOOL_META: Record<string, { emoji: string; verb: string }> = {
  bash: { emoji: "⚡", verb: "Running" },
  execute: { emoji: "⚡", verb: "Running" },
  read_file: { emoji: "📖", verb: "Reading" },
  write_file: { emoji: "✏️", verb: "Writing" },
  edit_file: { emoji: "✏️", verb: "Editing" },
  create_file: { emoji: "📄", verb: "Creating" },
  delete_file: { emoji: "🗑️", verb: "Deleting" },
  list_directory: { emoji: "📁", verb: "Listing" },
  search_files: { emoji: "🔍", verb: "Searching" },
  grep: { emoji: "🔍", verb: "Searching" },
  glob: { emoji: "🔍", verb: "Globbing" },
  web_search: { emoji: "🌐", verb: "Searching web" },
  fetch_url: { emoji: "🌐", verb: "Fetching" },
  computer: { emoji: "🖥️", verb: "Controlling" },
  screenshot: { emoji: "📷", verb: "Capturing" },
  think: { emoji: "💭", verb: "Thinking" },
  plan: { emoji: "📋", verb: "Planning" },
};

function metaForTool(tool: string): { emoji: string; verb: string } {
  // Normalize: strip namespaces like "str_replace_editor" → try suffix match
  const lower = tool.toLowerCase();
  for (const [key, meta] of Object.entries(TOOL_META)) {
    if (
      lower === key ||
      lower.endsWith(`_${key}`) ||
      lower.startsWith(`${key}_`)
    ) {
      return meta;
    }
  }
  return { emoji: "🔧", verb: "Running" };
}

function summaryFromInput(input: Record<string, unknown>): string {
  // Prefer common path/command fields
  const candidates = [
    "path",
    "file_path",
    "paths",
    "command",
    "pattern",
    "query",
    "url",
  ] as const;
  for (const key of candidates) {
    const val = input[key];
    if (typeof val === "string" && val.length > 0) {
      return val.length > 60 ? `${val.slice(0, 57)}…` : val;
    }
    if (Array.isArray(val) && typeof val[0] === "string") {
      return val[0].length > 60 ? `${val[0].slice(0, 57)}…` : val[0];
    }
  }
  const first = Object.values(input)[0];
  if (typeof first === "string")
    return first.length > 60 ? `${first.slice(0, 57)}…` : first;
  return "";
}

// ── Activity Store ────────────────────────────────────────────────────────────

class ActivityStore {
  /** Full ordered list of activities for the current stream session */
  activities = $state<Activity[]>([]);

  /** Controls how many / which activities the feed renders */
  verbosity = $state<VerbosityLevel>("new");

  /** Whether the feed panel is expanded */
  isExpanded = $state(false);

  // ── Derived ─────────────────────────────────────────────────────────────────

  /** The most recent still-running activity (shown in collapsed bar) */
  get currentActivity(): Activity | null {
    for (let i = this.activities.length - 1; i >= 0; i--) {
      if (this.activities[i].finishedAt === null) return this.activities[i];
    }
    // Fall back to last finished activity
    return this.activities[this.activities.length - 1] ?? null;
  }

  /** Activities visible under current verbosity settings */
  get visibleActivities(): Activity[] {
    if (this.verbosity === "off") return [];
    if (this.verbosity === "new") {
      // Only the most recent activity
      return this.activities.length > 0
        ? [this.activities[this.activities.length - 1]]
        : [];
    }
    if (this.verbosity === "all") return this.activities;
    // verbose — same list but components will render full input/output
    return this.activities;
  }

  /** Total elapsed ms for the entire session */
  get totalElapsedMs(): number {
    if (this.activities.length === 0) return 0;
    const start = this.activities[0].startedAt;
    const last = this.activities[this.activities.length - 1];
    const end = last.finishedAt ?? Date.now();
    return end - start;
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /** Feed raw SSE events from chatStore.addStreamListener() */
  handleEvent(event: StreamEvent): void {
    if (event.type === "tool_call") {
      this.#onToolCall(event);
    } else if (event.type === "tool_result") {
      this.#onToolResult(event);
    } else if (event.type === "done" || event.type === "error") {
      this.#onStreamEnd();
    }
  }

  /** Clear all activities — call when a new message is sent */
  clear(): void {
    this.activities = [];
    this.isExpanded = false;
  }

  /** Cycle verbosity: off → new → all → verbose → off */
  cycleVerbosity(): void {
    const cycle: VerbosityLevel[] = ["off", "new", "all", "verbose"];
    const idx = cycle.indexOf(this.verbosity);
    this.verbosity = cycle[(idx + 1) % cycle.length];
  }

  toggleExpanded(): void {
    this.isExpanded = !this.isExpanded;
  }

  // ── Private ─────────────────────────────────────────────────────────────────

  #onToolCall(event: ToolCallEvent): void {
    const meta = metaForTool(event.tool_name);
    const summary = summaryFromInput(event.input);
    const activity: Activity = {
      id: event.tool_use_id,
      tool: event.tool_name,
      label: `${meta.verb} ${summary}`.trim(),
      summary,
      emoji: meta.emoji,
      startedAt: Date.now(),
      finishedAt: null,
      isError: false,
    };
    this.activities = [...this.activities, activity];
    // Auto-expand when a tool call arrives (unless user set verbosity off)
    if (
      this.verbosity !== "off" &&
      !this.isExpanded &&
      this.activities.length > 1
    ) {
      // Keep collapsed — the bar will show currentActivity
    }
  }

  #onToolResult(event: ToolResultEvent): void {
    this.activities = this.activities.map((a) =>
      a.id === event.tool_use_id
        ? { ...a, finishedAt: Date.now(), isError: event.is_error }
        : a,
    );
  }

  #onStreamEnd(): void {
    // Mark any still-running activities as finished
    const now = Date.now();
    this.activities = this.activities.map((a) =>
      a.finishedAt === null ? { ...a, finishedAt: now } : a,
    );
  }
}

// ── Singleton Export ──────────────────────────────────────────────────────────

export const activityStore = new ActivityStore();
