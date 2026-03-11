<script lang="ts">
  import { slide } from "svelte/transition";
  import type { ActivityLog, LogLevel, LogSource } from "$lib/mock-data";

  // ── Props ─────────────────────────────────────────────────────────────────

  interface Props {
    logs: ActivityLog[];
    loading: boolean;
  }

  let { logs, loading }: Props = $props();

  // ── Expanded rows ─────────────────────────────────────────────────────────

  let expandedIds = $state<Set<string>>(new Set());

  function toggleExpand(id: string): void {
    const next = new Set(expandedIds);
    if (next.has(id)) {
      next.delete(id);
    } else {
      next.add(id);
    }
    expandedIds = next;
  }

  // ── Formatting helpers ────────────────────────────────────────────────────

  function formatTime(iso: string): string {
    try {
      const d = new Date(iso);
      const hh = String(d.getHours()).padStart(2, "0");
      const mm = String(d.getMinutes()).padStart(2, "0");
      const ss = String(d.getSeconds()).padStart(2, "0");
      return `${hh}:${mm}:${ss}`;
    } catch {
      return "—";
    }
  }

  function formatDate(iso: string): string {
    try {
      return new Date(iso).toLocaleDateString(undefined, {
        month: "short",
        day: "numeric",
      });
    } catch {
      return "";
    }
  }

  function levelClass(level: LogLevel): string {
    switch (level) {
      case "info":  return "level-info";
      case "warn":  return "level-warn";
      case "error": return "level-error";
      case "debug": return "level-debug";
    }
  }

  function sourceClass(source: LogSource): string {
    switch (source) {
      case "agent":           return "source-agent";
      case "system":          return "source-system";
      case "user":            return "source-user";
      case "api":             return "source-api";
      case "session":         return "source-session";
      case "tool":            return "source-tool";
      case "command-center":  return "source-command";
    }
  }

  function sourceLabel(source: LogSource): string {
    switch (source) {
      case "agent":           return "Agent";
      case "system":          return "System";
      case "user":            return "User";
      case "api":             return "API";
      case "session":         return "Session";
      case "tool":            return "Tool";
      case "command-center":  return "Cmd Center";
    }
  }
</script>

<div class="table-container" role="log" aria-label="Activity log entries" aria-live="polite">

  <!-- ── Column header ── -->
  <div class="table-head" role="row" aria-hidden="true">
    <span class="col-time">Time</span>
    <span class="col-level">Level</span>
    <span class="col-source">Source</span>
    <span class="col-message">Message</span>
  </div>

  <!-- ── Loading skeletons ── -->
  {#if loading && logs.length === 0}
    <div class="skeleton-list" aria-busy="true" aria-label="Loading logs">
      {#each { length: 5 } as _, i (i)}
        <div class="skeleton-row">
          <div class="skeleton skeleton-time"></div>
          <div class="skeleton skeleton-level"></div>
          <div class="skeleton skeleton-source"></div>
          <div class="skeleton skeleton-message" style="width: {60 + (i * 7) % 30}%"></div>
        </div>
      {/each}
    </div>

  <!-- ── Empty state ── -->
  {:else if logs.length === 0}
    <div class="empty-state" role="status">
      <div class="empty-icon" aria-hidden="true">
        <svg width="40" height="40" viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
          <rect x="6" y="8" width="28" height="24" rx="3" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.3"/>
          <line x1="11" y1="15" x2="29" y2="15" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.3"/>
          <line x1="11" y1="20" x2="24" y2="20" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.2"/>
          <line x1="11" y1="25" x2="20" y2="25" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.15"/>
        </svg>
      </div>
      <p class="empty-title">No log entries</p>
      <p class="empty-subtitle">Adjust filters or wait for activity to appear.</p>
    </div>

  <!-- ── Log rows ── -->
  {:else}
    <div class="log-list">
      {#each logs as entry (entry.id)}
        {@const isExpanded = expandedIds.has(entry.id)}
        {@const hasMetadata = entry.metadata !== undefined && Object.keys(entry.metadata).length > 0}

        <div
          class="log-row"
          class:log-row--error={entry.level === "error"}
          class:log-row--warn={entry.level === "warn"}
          class:log-row--expanded={isExpanded}
          role="row"
        >
          <!-- Main row content -->
          <div class="row-main">

            <!-- Timestamp -->
            <time
              class="col-time row-time"
              datetime={entry.timestamp}
              title={entry.timestamp}
            >
              {formatTime(entry.timestamp)}
              <span class="row-date">{formatDate(entry.timestamp)}</span>
            </time>

            <!-- Level badge -->
            <span
              class="col-level level-badge {levelClass(entry.level)}"
              role="img"
              aria-label="Level: {entry.level}"
            >
              {entry.level}
            </span>

            <!-- Source label -->
            <span
              class="col-source source-label {sourceClass(entry.source)}"
              aria-label="Source: {entry.source}"
            >
              {sourceLabel(entry.source)}
            </span>

            <!-- Message + expand toggle -->
            <div class="col-message message-cell">
              <span
                class="message-text"
                class:message-text--truncated={!isExpanded}
                title={!isExpanded ? entry.message : undefined}
              >
                {entry.message}
              </span>

              {#if hasMetadata}
                <button
                  class="expand-btn"
                  onclick={() => toggleExpand(entry.id)}
                  aria-expanded={isExpanded}
                  aria-controls="meta-{entry.id}"
                  aria-label="{isExpanded ? 'Collapse' : 'Expand'} metadata for log {entry.id}"
                >
                  <svg
                    class="expand-chevron"
                    class:expand-chevron--open={isExpanded}
                    width="10"
                    height="10"
                    viewBox="0 0 10 10"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    aria-hidden="true"
                  >
                    <polyline points="2,3.5 5,6.5 8,3.5"/>
                  </svg>
                </button>
              {/if}
            </div>
          </div>

          <!-- Expandable metadata -->
          {#if isExpanded && hasMetadata}
            <div
              id="meta-{entry.id}"
              class="metadata-panel"
              transition:slide={{ duration: 160 }}
            >
              <pre class="metadata-json">{JSON.stringify(entry.metadata, null, 2)}</pre>
            </div>
          {/if}
        </div>
      {/each}
    </div>
  {/if}

</div>

<style>
  /* ── Container ── */

  .table-container {
    display: flex;
    flex-direction: column;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-lg);
    overflow: hidden;
  }

  /* ── Column layout — shared between header and rows ── */

  .table-head,
  .row-main {
    display: grid;
    grid-template-columns: 90px 58px 102px 1fr;
    align-items: center;
    gap: 0;
  }

  /* ── Table header ── */

  .table-head {
    padding: 8px 16px;
    background: rgba(255, 255, 255, 0.025);
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    color: var(--text-tertiary);
    user-select: none;
  }

  /* ── Column alignment ── */

  .col-time    { padding-right: 12px; }
  .col-level   { padding-right: 10px; }
  .col-source  { padding-right: 10px; }
  .col-message { min-width: 0; }

  /* ── Skeleton loading ── */

  .skeleton-list {
    display: flex;
    flex-direction: column;
  }

  .skeleton-row {
    display: grid;
    grid-template-columns: 90px 58px 102px 1fr;
    align-items: center;
    padding: 10px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    gap: 0;
  }

  .skeleton {
    height: 10px;
    border-radius: var(--radius-xs);
    background: rgba(255, 255, 255, 0.06);
    animation: skeleton-pulse 1.5s ease-in-out infinite;
  }

  .skeleton-time    { width: 54px; }
  .skeleton-level   { width: 32px; }
  .skeleton-source  { width: 56px; }
  .skeleton-message { width: 60%; }

  @keyframes skeleton-pulse {
    0%, 100% { opacity: 0.6; }
    50%       { opacity: 0.25; }
  }

  /* ── Empty state ── */

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 64px 32px;
    gap: 10px;
    text-align: center;
  }

  .empty-icon {
    color: rgba(255, 255, 255, 0.1);
    margin-bottom: 4px;
  }

  .empty-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .empty-subtitle {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    line-height: 1.5;
    max-width: 260px;
  }

  /* ── Log list ── */

  .log-list {
    display: flex;
    flex-direction: column;
  }

  /* ── Log row ── */

  .log-row {
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    transition: background 0.1s;
  }

  .log-row:last-child {
    border-bottom: none;
  }

  .log-row:hover {
    background: rgba(255, 255, 255, 0.025);
  }

  .log-row--error {
    border-left: 2px solid rgba(239, 68, 68, 0.35);
    background: rgba(239, 68, 68, 0.025);
  }

  .log-row--error:hover {
    background: rgba(239, 68, 68, 0.04);
  }

  .log-row--warn {
    border-left: 2px solid rgba(245, 158, 11, 0.3);
  }

  .log-row--expanded {
    background: rgba(255, 255, 255, 0.02);
  }

  /* rows without an error/warn border still need the left space for alignment */
  .log-row:not(.log-row--error):not(.log-row--warn) {
    border-left: 2px solid transparent;
  }

  .row-main {
    padding: 9px 14px 9px 14px;
    cursor: default;
  }

  /* ── Timestamp ── */

  .row-time {
    font-size: 0.75rem;
    font-family: var(--font-mono);
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
    display: flex;
    flex-direction: column;
    gap: 1px;
    line-height: 1.2;
    user-select: text;
  }

  .row-date {
    font-size: 0.625rem;
    color: var(--text-muted);
    font-family: var(--font-mono);
  }

  /* ── Level badge ── */

  .level-badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 2px 6px;
    border-radius: var(--radius-xs);
    font-size: 0.625rem;
    font-weight: 700;
    letter-spacing: 0.05em;
    text-transform: uppercase;
    width: fit-content;
    user-select: none;
  }

  .level-info {
    background: rgba(59, 130, 246, 0.12);
    color: rgba(96, 165, 250, 0.9);
    border: 1px solid rgba(59, 130, 246, 0.18);
  }

  .level-warn {
    background: rgba(245, 158, 11, 0.12);
    color: rgba(251, 191, 36, 0.9);
    border: 1px solid rgba(245, 158, 11, 0.18);
  }

  .level-error {
    background: rgba(239, 68, 68, 0.13);
    color: rgba(252, 100, 100, 0.95);
    border: 1px solid rgba(239, 68, 68, 0.2);
  }

  .level-debug {
    background: rgba(255, 255, 255, 0.05);
    color: var(--text-tertiary);
    border: 1px solid rgba(255, 255, 255, 0.07);
  }

  /* ── Source label ── */

  .source-label {
    font-size: 0.6875rem;
    font-weight: 500;
    color: var(--text-tertiary);
    user-select: none;
  }

  .source-agent   { color: rgba(167, 139, 250, 0.85); }
  .source-system  { color: rgba(156, 163, 175, 0.8);  }
  .source-user    { color: rgba(52, 211, 153, 0.8);   }
  .source-api     { color: rgba(96, 165, 250, 0.8);   }
  .source-session { color: rgba(52, 211, 153, 0.75);  }
  .source-tool    { color: rgba(251, 191, 36, 0.8);   }
  .source-command { color: rgba(251, 146, 60, 0.8);   }

  /* ── Message cell ── */

  .message-cell {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    user-select: text;
  }

  .message-text {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.4;
    flex: 1;
    min-width: 0;
  }

  .message-text--truncated {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* ── Expand button ── */

  .expand-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    border: none;
    background: none;
    color: var(--text-tertiary);
    border-radius: var(--radius-xs);
    flex-shrink: 0;
    transition: color 0.15s, background 0.15s;
  }

  .expand-btn:hover {
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.06);
  }

  .expand-chevron {
    transition: transform 0.18s ease;
  }

  .expand-chevron--open {
    transform: rotate(180deg);
  }

  /* ── Metadata panel ── */

  .metadata-panel {
    padding: 0 16px 12px 16px;
  }

  .metadata-json {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-sm);
    padding: 10px 12px;
    white-space: pre-wrap;
    word-break: break-all;
    line-height: 1.6;
    user-select: text;
    margin: 0;
    max-height: 200px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }
</style>
