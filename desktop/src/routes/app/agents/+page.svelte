<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { slide } from 'svelte/transition';
  import { agentsStore } from '$lib/stores/agents.svelte';
  import { agents as agentsApi } from '$lib/api/client';
  import { restartBackend } from '$lib/utils/backend';
  import type { Agent, AgentStatus } from '$lib/api/types';
  import AgentTree from '$lib/components/agents/AgentTree.svelte';

  // ── View mode (grid | tree) ──────────────────────────────────────────────────

  type ViewMode = 'grid' | 'tree';

  function loadViewMode(): ViewMode {
    try {
      const stored = localStorage.getItem('osa:agents:view');
      if (stored === 'tree' || stored === 'grid') return stored;
    } catch { /* ignore */ }
    return 'grid';
  }

  let viewMode = $state<ViewMode>(loadViewMode());

  function setViewMode(mode: ViewMode) {
    viewMode = mode;
    try {
      localStorage.setItem('osa:agents:view', mode);
    } catch { /* ignore */ }
  }

  // ── Polling ──────────────────────────────────────────────────────────────────

  let pollTimer: ReturnType<typeof setInterval> | null = null;

  onMount(() => {
    agentsStore.fetchAgents();
    pollTimer = setInterval(() => {
      agentsStore.fetchAgents();
    }, 5000);
  });

  onDestroy(() => {
    if (pollTimer !== null) clearInterval(pollTimer);
  });

  // ── Expand state (per-card) ──────────────────────────────────────────────────

  let expandedIds = $state<Set<string>>(new Set());

  function toggleExpand(id: string) {
    const next = new Set(expandedIds);
    if (next.has(id)) {
      next.delete(id);
    } else {
      next.add(id);
    }
    expandedIds = next;
  }

  // ── Optimistic actions ───────────────────────────────────────────────────────

  let pendingIds = $state<Set<string>>(new Set());

  async function handlePause(agent: Agent) {
    pendingIds = new Set([...pendingIds, agent.id]);
    try {
      await agentsApi.pause(agent.id);
      agentsStore.setAgentStatus(agent.id, 'idle');
    } catch {
      // silently revert — next poll will correct state
    } finally {
      const next = new Set(pendingIds);
      next.delete(agent.id);
      pendingIds = next;
    }
  }

  async function handleCancel(agent: Agent) {
    pendingIds = new Set([...pendingIds, agent.id]);
    try {
      await agentsApi.cancel(agent.id);
      agentsStore.setAgentStatus(agent.id, 'idle');
    } catch {
      // silently revert — next poll will correct state
    } finally {
      const next = new Set(pendingIds);
      next.delete(agent.id);
      pendingIds = next;
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function formatDuration(seconds: number | undefined): string {
    if (seconds === undefined) return '—';
    if (seconds < 60) return `${Math.round(seconds)}s`;
    const m = Math.floor(seconds / 60);
    const s = Math.round(seconds % 60);
    return `${m}m ${s}s`;
  }

  function formatTokens(tokens: number | undefined): string {
    if (tokens === undefined) return '—';
    if (tokens >= 1000) return `${(tokens / 1000).toFixed(1)}k`;
    return String(tokens);
  }

  function formatRelative(iso: string): string {
    const diff = Date.now() - new Date(iso).getTime();
    const s = Math.floor(diff / 1000);
    if (s < 60) return 'just now';
    const m = Math.floor(s / 60);
    if (m < 60) return `${m}m ago`;
    const h = Math.floor(m / 60);
    if (h < 24) return `${h}h ago`;
    return `${Math.floor(h / 24)}d ago`;
  }

  function statusLabel(status: AgentStatus): string {
    switch (status) {
      case 'running': return 'Running';
      case 'queued':  return 'Queued';
      case 'done':    return 'Done';
      case 'error':   return 'Failed';
      case 'idle':    return 'Idle';
    }
  }

  // Sort: running first, then queued, then idle, then done, then error
  const STATUS_ORDER: Record<AgentStatus, number> = {
    running: 0,
    queued:  1,
    idle:    2,
    done:    3,
    error:   4,
  };

  const sortedAgents = $derived(
    [...agentsStore.agents].sort(
      (a, b) => STATUS_ORDER[a.status] - STATUS_ORDER[b.status],
    ),
  );
</script>

<!-- ── Page shell ──────────────────────────────────────────────────────────── -->
<div class="agents-page">

  <!-- ── Header ── -->
  <header class="page-header">
    <div class="header-left">
      <h1 class="page-title">Agents</h1>
      {#if agentsStore.lastUpdated}
        <span class="last-updated" aria-live="polite">
          Updated {formatRelative(agentsStore.lastUpdated.toISOString())}
        </span>
      {/if}
    </div>

    <!-- View mode toggle -->
    <div class="view-toggle" role="group" aria-label="View mode">
      <button
        class="view-btn"
        class:view-btn--active={viewMode === 'grid'}
        onclick={() => setViewMode('grid')}
        aria-pressed={viewMode === 'grid'}
        aria-label="Grid view"
        title="Grid view"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" fill="currentColor" aria-hidden="true">
          <rect x="1" y="1" width="5" height="5" rx="1.5"/>
          <rect x="8" y="1" width="5" height="5" rx="1.5"/>
          <rect x="1" y="8" width="5" height="5" rx="1.5"/>
          <rect x="8" y="8" width="5" height="5" rx="1.5"/>
        </svg>
        <span class="view-btn-label">Grid</span>
      </button>
      <button
        class="view-btn"
        class:view-btn--active={viewMode === 'tree'}
        onclick={() => setViewMode('tree')}
        aria-pressed={viewMode === 'tree'}
        aria-label="Tree view"
        title="Tree view"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
          <circle cx="7" cy="2.5" r="1.5" fill="currentColor" stroke="none"/>
          <circle cx="3" cy="11" r="1.5" fill="currentColor" stroke="none"/>
          <circle cx="11" cy="11" r="1.5" fill="currentColor" stroke="none"/>
          <line x1="7" y1="4" x2="3" y2="9.5"/>
          <line x1="7" y1="4" x2="11" y2="9.5"/>
        </svg>
        <span class="view-btn-label">Tree</span>
      </button>
    </div>

    <div class="stats-bar" role="status" aria-label="Agent statistics">
      <div class="stat stat--running">
        <span class="stat-dot stat-dot--running" aria-hidden="true"></span>
        <span class="stat-value">{agentsStore.runningCount}</span>
        <span class="stat-label">running</span>
      </div>
      <div class="stat-divider" aria-hidden="true"></div>
      <div class="stat">
        <span class="stat-value">{agentsStore.completedCount}</span>
        <span class="stat-label">done</span>
      </div>
      <div class="stat-divider" aria-hidden="true"></div>
      {#if agentsStore.failedCount > 0}
        <div class="stat stat--error">
          <span class="stat-value">{agentsStore.failedCount}</span>
          <span class="stat-label">failed</span>
        </div>
        <div class="stat-divider" aria-hidden="true"></div>
      {/if}
      <div class="stat">
        <span class="stat-value">{agentsStore.totalCount}</span>
        <span class="stat-label">total</span>
      </div>

      {#if agentsStore.loading}
        <span class="loading-spinner" aria-label="Refreshing"></span>
      {/if}
    </div>
  </header>

  <!-- ── Content ── -->
  <main class="page-content" id="agents-main">

    {#if agentsStore.error}
      <div class="status-banner" role="status">
        <span class="status-banner-dot"></span>
        <span class="status-banner-text">Backend offline</span>
        <span class="status-banner-hint">Start OSA backend on port 9089</span>
        <button
          class="status-banner-btn"
          onclick={() => { restartBackend().catch(() => {}); }}
          aria-label="Restart backend"
        >
          Restart
        </button>
        <button
          class="status-banner-btn"
          onclick={() => agentsStore.fetchAgents()}
          aria-label="Retry fetching agents"
        >
          Retry
        </button>
      </div>
    {/if}

    {#if viewMode === 'tree'}
      <!-- ── Tree view ── -->
      <AgentTree />

    {:else if sortedAgents.length === 0 && !agentsStore.loading}
      <!-- ── Empty state ── -->
      <div class="empty-state" role="status">
        <div class="empty-icon" aria-hidden="true">
          <svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
            <rect x="8" y="8" width="14" height="14" rx="3" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.4"/>
            <rect x="26" y="8" width="14" height="14" rx="3" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.25"/>
            <rect x="8" y="26" width="14" height="14" rx="3" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.25"/>
            <rect x="26" y="26" width="14" height="14" rx="3" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.15"/>
            <circle cx="15" cy="15" r="2.5" fill="currentColor" opacity="0.5"/>
          </svg>
        </div>
        <p class="empty-title">No agents running</p>
        <p class="empty-subtitle">Agents will appear here when a task is dispatched from chat.</p>
      </div>

    {:else}
      <!-- ── Agent grid ── -->
      <div class="agent-grid" role="list" aria-label="Agent list">
        {#each sortedAgents as agent (agent.id)}
          <article
            class="agent-card"
            class:agent-card--running={agent.status === 'running'}
            class:agent-card--queued={agent.status === 'queued'}
            class:agent-card--done={agent.status === 'done'}
            class:agent-card--error={agent.status === 'error'}
            role="listitem"
          >
            <!-- ── Card header ── -->
            <div class="card-header">
              <div class="card-header-left">
                <div class="status-indicator" aria-hidden="true">
                  <span
                    class="status-dot"
                    class:status-dot--running={agent.status === 'running'}
                    class:status-dot--queued={agent.status === 'queued'}
                    class:status-dot--done={agent.status === 'done'}
                    class:status-dot--error={agent.status === 'error'}
                    class:status-dot--idle={agent.status === 'idle'}
                  ></span>
                </div>
                <div class="agent-identity">
                  <h2 class="agent-name">{agent.name}</h2>
                  <span
                    class="status-badge"
                    class:status-badge--running={agent.status === 'running'}
                    class:status-badge--queued={agent.status === 'queued'}
                    class:status-badge--done={agent.status === 'done'}
                    class:status-badge--error={agent.status === 'error'}
                  >
                    {statusLabel(agent.status)}
                  </span>
                </div>
              </div>

              <!-- Card actions -->
              <div class="card-actions">
                {#if agent.status === 'running' || agent.status === 'queued'}
                  <button
                    class="action-btn action-btn--pause"
                    onclick={() => handlePause(agent)}
                    disabled={pendingIds.has(agent.id)}
                    aria-label="Pause agent {agent.name}"
                  >
                    <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
                      <rect x="2" y="1.5" width="3" height="9" rx="1"/>
                      <rect x="7" y="1.5" width="3" height="9" rx="1"/>
                    </svg>
                  </button>
                  <button
                    class="action-btn action-btn--cancel"
                    onclick={() => handleCancel(agent)}
                    disabled={pendingIds.has(agent.id)}
                    aria-label="Cancel agent {agent.name}"
                  >
                    <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
                      <line x1="1.5" y1="1.5" x2="8.5" y2="8.5"/>
                      <line x1="8.5" y1="1.5" x2="1.5" y2="8.5"/>
                    </svg>
                  </button>
                {/if}

                <button
                  class="action-btn action-btn--expand"
                  onclick={() => toggleExpand(agent.id)}
                  aria-expanded={expandedIds.has(agent.id)}
                  aria-controls="agent-log-{agent.id}"
                  aria-label="{expandedIds.has(agent.id) ? 'Collapse' : 'Expand'} details for {agent.name}"
                >
                  <span
                    class="chevron"
                    class:chevron--open={expandedIds.has(agent.id)}
                    aria-hidden="true"
                  >›</span>
                </button>
              </div>
            </div>

            <!-- ── Current action (if running) ── -->
            {#if agent.task && (agent.status === 'running' || agent.status === 'queued')}
              <p class="current-action truncate" title={agent.task}>
                <span class="current-action-prefix" aria-hidden="true">›</span>
                {agent.task}
              </p>
            {/if}

            <!-- ── Progress bar (running/queued only) ── -->
            {#if (agent.status === 'running' || agent.status === 'queued') && agent.progress > 0}
              <div
                class="progress-track"
                role="progressbar"
                aria-valuenow={agent.progress}
                aria-valuemin={0}
                aria-valuemax={100}
                aria-label="Agent progress"
              >
                <div class="progress-fill" style="width: {agent.progress}%"></div>
              </div>
            {/if}

            <!-- ── Metrics row ── -->
            <div class="metrics-row" aria-label="Agent metrics">
              <div class="metric">
                <span class="metric-label">Duration</span>
                <span class="metric-value">{formatDuration(agent.duration)}</span>
              </div>
              <div class="metric">
                <span class="metric-label">Tokens</span>
                <span class="metric-value">{formatTokens(agent.tokens)}</span>
              </div>
              <div class="metric">
                <span class="metric-label">Started</span>
                <span class="metric-value">{formatRelative(agent.created_at)}</span>
              </div>
            </div>

            <!-- ── Expanded log ── -->
            {#if expandedIds.has(agent.id)}
              <div
                id="agent-log-{agent.id}"
                class="agent-log"
                transition:slide={{ duration: 180 }}
              >
                <div class="log-divider" aria-hidden="true"></div>

                {#if agent.error}
                  <div class="log-error" role="alert">
                    <p class="log-section-label">Error</p>
                    <pre class="log-text log-text--error">{agent.error}</pre>
                  </div>
                {/if}

                {#if agent.task}
                  <div class="log-task">
                    <p class="log-section-label">Task</p>
                    <p class="log-text">{agent.task}</p>
                  </div>
                {/if}

                <div class="log-meta">
                  <p class="log-section-label">Agent ID</p>
                  <code class="log-id">{agent.id}</code>
                </div>

                <div class="log-meta">
                  <p class="log-section-label">Last updated</p>
                  <span class="log-text">{formatRelative(agent.updated_at)}</span>
                </div>
              </div>
            {/if}
          </article>
        {/each}
      </div>
    {/if}
  </main>
</div>

<style>
  /* ── Page layout ── */

  .agents-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  /* ── Header ── */

  .page-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 24px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
    gap: 16px;
    flex-wrap: wrap;
  }

  .header-left {
    display: flex;
    align-items: baseline;
    gap: 12px;
  }

  .page-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.01em;
  }

  .last-updated {
    font-size: 0.75rem;
    color: var(--text-tertiary);
  }

  /* ── View toggle ── */

  .view-toggle {
    display: flex;
    align-items: center;
    gap: 2px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-md);
    padding: 3px;
  }

  .view-btn {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 4px 9px;
    border-radius: calc(var(--radius-md) - 3px);
    border: none;
    background: none;
    color: var(--text-tertiary);
    font-size: 0.75rem;
    font-weight: 500;
    transition: all 0.15s;
    line-height: 1;
  }

  .view-btn:hover:not(.view-btn--active) {
    background: rgba(255, 255, 255, 0.05);
    color: var(--text-secondary);
  }

  .view-btn--active {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text-primary);
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.2);
  }

  .view-btn-label {
    font-size: 0.6875rem;
    letter-spacing: 0.02em;
  }

  /* ── Stats bar ── */

  .stats-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    padding: 6px 14px;
  }

  .stat {
    display: flex;
    align-items: center;
    gap: 5px;
  }

  .stat--running .stat-value {
    color: var(--accent-success);
  }

  .stat--error .stat-value {
    color: var(--accent-error);
  }

  .stat-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text-tertiary);
  }

  .stat-dot--running {
    background: var(--accent-success);
    animation: pulse-dot 2s ease-in-out infinite;
  }

  @keyframes pulse-dot {
    0%, 100% { opacity: 1; transform: scale(1); }
    50%       { opacity: 0.6; transform: scale(0.8); }
  }

  .stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
  }

  .stat-label {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .stat-divider {
    width: 1px;
    height: 12px;
    background: rgba(255, 255, 255, 0.08);
  }

  .loading-spinner {
    width: 12px;
    height: 12px;
    border: 1.5px solid rgba(255, 255, 255, 0.1);
    border-top-color: rgba(255, 255, 255, 0.5);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
    flex-shrink: 0;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  /* ── Content ── */

  .page-content {
    flex: 1;
    overflow-y: auto;
    padding: 20px 24px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  /* ── Status banner (subtle, not alarming) ── */

  .status-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 16px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md);
    font-size: 0.7rem;
    color: var(--text-tertiary);
    margin-bottom: 16px;
  }

  .status-banner-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .status-banner-text {
    color: var(--text-secondary);
  }

  .status-banner-hint {
    margin-left: auto;
    color: var(--text-muted);
  }

  .status-banner-btn {
    padding: 3px 10px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.65rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
    flex-shrink: 0;
  }

  .status-banner-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
  }

  /* ── Empty state ── */

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 320px;
    gap: 12px;
    color: var(--text-tertiary);
    text-align: center;
    padding: 48px 32px;
  }

  .empty-icon {
    color: rgba(255, 255, 255, 0.12);
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
    max-width: 280px;
    line-height: 1.5;
  }

  /* ── Agent grid ── */

  .agent-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 12px;
  }

  @media (max-width: 720px) {
    .agent-grid {
      grid-template-columns: 1fr;
    }
  }

  /* ── Agent card ── */

  .agent-card {
    background: rgba(255, 255, 255, 0.04);
    backdrop-filter: blur(24px);
    -webkit-backdrop-filter: blur(24px);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-xl);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    transition:
      border-color 0.2s ease,
      box-shadow 0.2s ease;
  }

  .agent-card--running {
    border-color: rgba(34, 197, 94, 0.2);
    box-shadow:
      0 0 0 1px rgba(34, 197, 94, 0.06),
      inset 0 1px 0 rgba(34, 197, 94, 0.06);
  }

  .agent-card--queued {
    border-color: rgba(59, 130, 246, 0.2);
    box-shadow: 0 0 0 1px rgba(59, 130, 246, 0.06);
  }

  .agent-card--error {
    border-color: rgba(239, 68, 68, 0.2);
    box-shadow: 0 0 0 1px rgba(239, 68, 68, 0.06);
  }

  .agent-card--done {
    opacity: 0.75;
  }

  /* ── Card header ── */

  .card-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 8px;
  }

  .card-header-left {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
    flex: 1;
  }

  /* ── Status dot ── */

  .status-indicator {
    flex-shrink: 0;
  }

  .status-dot {
    display: block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.2);
  }

  .status-dot--running {
    background: var(--accent-success);
    box-shadow: 0 0 6px rgba(34, 197, 94, 0.5);
    animation: pulse-glow 2s ease-in-out infinite;
  }

  .status-dot--queued {
    background: var(--accent-primary);
    box-shadow: 0 0 6px rgba(59, 130, 246, 0.4);
    animation: pulse-glow-blue 2s ease-in-out infinite;
  }

  .status-dot--done {
    background: rgba(255, 255, 255, 0.25);
  }

  .status-dot--error {
    background: var(--accent-error);
    box-shadow: 0 0 6px rgba(239, 68, 68, 0.4);
  }

  .status-dot--idle {
    background: rgba(255, 255, 255, 0.18);
  }

  @keyframes pulse-glow {
    0%, 100% { box-shadow: 0 0 4px rgba(34, 197, 94, 0.4); }
    50%       { box-shadow: 0 0 10px rgba(34, 197, 94, 0.7); }
  }

  @keyframes pulse-glow-blue {
    0%, 100% { box-shadow: 0 0 4px rgba(59, 130, 246, 0.3); }
    50%       { box-shadow: 0 0 10px rgba(59, 130, 246, 0.6); }
  }

  /* ── Agent identity ── */

  .agent-identity {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }

  .agent-name {
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text-primary);
    line-height: 1.2;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .status-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 7px;
    border-radius: var(--radius-full);
    font-size: 0.625rem;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    width: fit-content;
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-tertiary);
    border: 1px solid rgba(255, 255, 255, 0.06);
  }

  .status-badge--running {
    background: rgba(34, 197, 94, 0.12);
    color: rgba(34, 197, 94, 0.9);
    border-color: rgba(34, 197, 94, 0.2);
  }

  .status-badge--queued {
    background: rgba(59, 130, 246, 0.12);
    color: rgba(59, 130, 246, 0.9);
    border-color: rgba(59, 130, 246, 0.2);
  }

  .status-badge--done {
    background: rgba(255, 255, 255, 0.06);
    color: rgba(255, 255, 255, 0.4);
    border-color: rgba(255, 255, 255, 0.06);
  }

  .status-badge--error {
    background: rgba(239, 68, 68, 0.12);
    color: rgba(239, 68, 68, 0.9);
    border-color: rgba(239, 68, 68, 0.2);
  }

  /* ── Card actions ── */

  .card-actions {
    display: flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
  }

  .action-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    border-radius: var(--radius-sm);
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.4);
    transition: all 0.15s;
  }

  .action-btn:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.06);
    color: rgba(255, 255, 255, 0.7);
    border-color: rgba(255, 255, 255, 0.15);
  }

  .action-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .action-btn--cancel:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.1);
    color: rgba(239, 68, 68, 0.8);
    border-color: rgba(239, 68, 68, 0.2);
  }

  .action-btn--expand {
    border-color: transparent;
  }

  .chevron {
    font-size: 1rem;
    color: rgba(255, 255, 255, 0.3);
    transition: transform 0.18s ease;
    display: inline-block;
    line-height: 1;
  }

  .chevron--open {
    transform: rotate(90deg);
  }

  /* ── Current action ── */

  .current-action {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.4;
    padding: 0 2px;
    display: flex;
    align-items: baseline;
    gap: 6px;
  }

  .current-action-prefix {
    color: var(--accent-success);
    font-weight: 600;
    flex-shrink: 0;
    opacity: 0.7;
  }

  /* ── Progress bar ── */

  .progress-track {
    height: 2px;
    background: rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    overflow: hidden;
  }

  .progress-fill {
    height: 100%;
    background: linear-gradient(
      90deg,
      rgba(34, 197, 94, 0.6),
      rgba(34, 197, 94, 0.9)
    );
    border-radius: var(--radius-full);
    transition: width 0.4s ease;
  }

  .agent-card--queued .progress-fill {
    background: linear-gradient(
      90deg,
      rgba(59, 130, 246, 0.6),
      rgba(59, 130, 246, 0.9)
    );
  }

  /* ── Metrics row ── */

  .metrics-row {
    display: flex;
    gap: 0;
    background: rgba(255, 255, 255, 0.025);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-md);
    overflow: hidden;
  }

  .metric {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 8px 10px;
    border-right: 1px solid rgba(255, 255, 255, 0.05);
  }

  .metric:last-child {
    border-right: none;
  }

  .metric-label {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .metric-value {
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
  }

  /* ── Expanded log ── */

  .log-divider {
    height: 1px;
    background: linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.06), transparent);
    margin-bottom: 10px;
  }

  .agent-log {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .log-section-label {
    font-size: 0.625rem;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.2);
    margin-bottom: 4px;
  }

  .log-text {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.5;
  }

  .log-text--error {
    color: rgba(239, 68, 68, 0.8);
    font-family: var(--font-mono);
    font-size: 0.75rem;
    background: rgba(239, 68, 68, 0.05);
    border: 1px solid rgba(239, 68, 68, 0.1);
    border-radius: var(--radius-sm);
    padding: 8px 10px;
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 120px;
    overflow-y: auto;
    margin: 0;
  }

  .log-id {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.03);
    padding: 3px 7px;
    border-radius: var(--radius-xs);
    border: 1px solid rgba(255, 255, 255, 0.05);
    user-select: text;
  }
</style>
