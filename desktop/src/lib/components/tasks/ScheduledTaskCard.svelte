<script lang="ts">
  import type { ScheduledTask } from '$lib/stores/scheduledTasks.svelte';
  import type { ScheduledRunStatus } from '$lib/api/types';

  interface Props {
    task: ScheduledTask;
    onPause?: (id: string) => void;
    onResume?: (id: string) => void;
    onDelete?: (id: string) => void;
    onEdit?: (id: string) => void;
    onRunNow?: (id: string) => void;
  }

  let { task, onPause, onResume, onDelete, onEdit, onRunNow }: Props = $props();

  function formatRelative(iso: string | null): string {
    if (!iso) return 'Never';
    const diff = Date.now() - new Date(iso).getTime();
    const abs = Math.abs(diff);
    const future = diff < 0;
    const s = Math.floor(abs / 1000);
    if (s < 60) return future ? 'in a moment' : 'just now';
    const m = Math.floor(s / 60);
    if (m < 60) return future ? `in ${m}m` : `${m}m ago`;
    const h = Math.floor(m / 60);
    if (h < 24) return future ? `in ${h}h` : `${h}h ago`;
    const d = Math.floor(h / 24);
    return future ? `in ${d}d` : `${d}d ago`;
  }

  function statusLabel(status: ScheduledTask['status']): string {
    switch (status) { case 'active': return 'Active'; case 'paused': return 'Paused'; case 'failed': return 'Failed'; }
  }

  function runDotColor(status: ScheduledRunStatus): string {
    switch (status) {
      case 'succeeded': return 'var(--accent-success)';
      case 'failed':    return 'var(--accent-error)';
      case 'running':   return 'var(--accent-warning)';
      case 'timed_out': return 'rgba(239, 68, 68, 0.6)';
      default:          return 'rgba(255, 255, 255, 0.2)';
    }
  }

  const isActive   = $derived(task.status === 'active');
  const isPaused   = $derived(task.status === 'paused');
  const isFailed   = $derived(task.status === 'failed');
  const recentRuns = $derived((task.recent_runs ?? []).slice(0, 5));
</script>

<article
  class="stask-card"
  class:stask-card--active={isActive}
  class:stask-card--paused={isPaused}
  class:stask-card--failed={isFailed}
  aria-label="Scheduled task: {task.name}"
>
  <div class="stask-header">
    <div class="stask-header-left">
      <span
        class="stask-dot"
        class:stask-dot--active={isActive}
        class:stask-dot--paused={isPaused}
        class:stask-dot--failed={isFailed}
        aria-hidden="true"
      ></span>

      <div class="stask-identity">
        <h3 class="stask-name">{task.name}</h3>
        <span
          class="stask-badge"
          class:stask-badge--active={isActive}
          class:stask-badge--paused={isPaused}
          class:stask-badge--failed={isFailed}
        >
          {statusLabel(task.status)}
        </span>
      </div>
    </div>

    <!-- Run history dots -->
    {#if recentRuns.length > 0}
      <div class="stask-run-dots" aria-label="Recent run history">
        {#each recentRuns as run}
          <span
            class="stask-run-dot"
            style="background: {runDotColor(run.status)}"
            title="{run.status} — {formatRelative(run.started_at)}"
          ></span>
        {/each}
      </div>
    {/if}

    <!-- Action buttons (visible on hover) -->
    <div class="stask-actions" role="group" aria-label="Task actions for {task.name}">
      {#if onRunNow}
        <button
          class="stask-btn stask-btn--run"
          onclick={() => onRunNow?.(task.id)}
          aria-label="Run {task.name} now"
          title="Run Now"
        >
          <svg width="11" height="11" viewBox="0 0 11 11" fill="currentColor" aria-hidden="true">
            <polygon points="2,1 10,5.5 2,10"/>
          </svg>
        </button>
      {/if}

      {#if isActive}
        <button
          class="stask-btn stask-btn--pause"
          onclick={() => onPause?.(task.id)}
          aria-label="Pause {task.name}"
          title="Pause"
        >
          <svg width="11" height="11" viewBox="0 0 11 11" fill="currentColor" aria-hidden="true">
            <rect x="1.5" y="1" width="3" height="9" rx="1"/>
            <rect x="6.5" y="1" width="3" height="9" rx="1"/>
          </svg>
        </button>
      {:else if isPaused}
        <button
          class="stask-btn stask-btn--resume"
          onclick={() => onResume?.(task.id)}
          aria-label="Resume {task.name}"
          title="Resume"
        >
          <svg width="11" height="11" viewBox="0 0 11 11" fill="currentColor" aria-hidden="true">
            <polygon points="2,1 10,5.5 2,10"/>
          </svg>
        </button>
      {:else if isFailed}
        <button
          class="stask-btn stask-btn--resume"
          onclick={() => onResume?.(task.id)}
          aria-label="Retry {task.name}"
          title="Retry"
        >
          <svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
            <path d="M1.5 5.5A4 4 0 0 1 9.5 3.2"/>
            <polyline points="7.5,1.5 9.5,3.2 7.5,4.9" fill="none"/>
          </svg>
        </button>
      {/if}

      <button
        class="stask-btn"
        onclick={() => onEdit?.(task.id)}
        aria-label="Edit {task.name}"
        title="Edit"
      >
        <svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M7.5 1.5l2 2L3 10H1v-2L7.5 1.5z"/>
        </svg>
      </button>

      <button
        class="stask-btn stask-btn--delete"
        onclick={() => onDelete?.(task.id)}
        aria-label="Delete {task.name}"
        title="Delete"
      >
        <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
          <line x1="1.5" y1="1.5" x2="8.5" y2="8.5"/>
          <line x1="8.5" y1="1.5" x2="1.5" y2="8.5"/>
        </svg>
      </button>
    </div>
  </div>

  {#if task.description}
    <p class="stask-description truncate" title={task.description}>
      {task.description}
    </p>
  {/if}

  {#if isFailed && task.last_error}
    <div class="stask-error" role="alert">
      <span class="stask-error-label">Last error</span>
      <span class="stask-error-text truncate">{task.last_error}</span>
    </div>
  {/if}

  <div class="stask-meta" aria-label="Task schedule details">
    <div class="stask-meta-item">
      <span class="stask-meta-label">Schedule</span>
      <code class="stask-schedule">{task.schedule}</code>
    </div>
    <div class="stask-meta-item">
      <span class="stask-meta-label">Last run</span>
      <span class="stask-meta-value">{formatRelative(task.last_run)}</span>
    </div>
    <div class="stask-meta-item">
      <span class="stask-meta-label">Next run</span>
      <span class="stask-meta-value">{formatRelative(task.next_run)}</span>
    </div>
    <div class="stask-meta-item">
      <span class="stask-meta-label">Runs</span>
      <span class="stask-meta-value stask-meta-value--mono">{task.failure_count > 0 ? `${task.failure_count} fail` : '—'}</span>
    </div>
  </div>
</article>

<style>
  .stask-card {
    background: var(--bg-surface);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    transition:
      border-color 0.2s ease,
      box-shadow 0.2s ease;
  }

  .stask-card--active {
    border-color: rgba(34, 197, 94, 0.18);
    box-shadow: 0 0 0 1px rgba(34, 197, 94, 0.05);
  }

  .stask-card--failed {
    border-color: rgba(239, 68, 68, 0.2);
    box-shadow: 0 0 0 1px rgba(239, 68, 68, 0.05);
  }

  .stask-card--paused {
    opacity: 0.72;
  }

  .stask-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 8px;
  }

  .stask-header-left {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
    flex: 1;
  }

  .stask-dot {
    display: block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.2);
    flex-shrink: 0;
  }

  .stask-dot--active {
    background: var(--accent-success);
    box-shadow: 0 0 6px rgba(34, 197, 94, 0.5);
    animation: stask-pulse 2s ease-in-out infinite;
  }

  .stask-dot--paused {
    background: var(--accent-warning);
  }

  .stask-dot--failed {
    background: var(--accent-error);
    box-shadow: 0 0 5px rgba(239, 68, 68, 0.4);
  }

  @keyframes stask-pulse {
    0%, 100% { box-shadow: 0 0 4px rgba(34, 197, 94, 0.4); }
    50%       { box-shadow: 0 0 10px rgba(34, 197, 94, 0.7); }
  }

  .stask-identity {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }

  .stask-name {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary);
    line-height: 1.2;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .stask-badge {
    display: inline-flex;
    align-items: center;
    padding: 1px 7px;
    border-radius: var(--radius-full);
    font-size: 0.6rem;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    width: fit-content;
    background: rgba(255, 255, 255, 0.07);
    color: var(--text-tertiary);
    border: 1px solid rgba(255, 255, 255, 0.06);
  }

  .stask-badge--active {
    background: rgba(34, 197, 94, 0.1);
    color: rgba(34, 197, 94, 0.85);
    border-color: rgba(34, 197, 94, 0.18);
  }

  .stask-badge--paused {
    background: rgba(245, 158, 11, 0.1);
    color: rgba(245, 158, 11, 0.85);
    border-color: rgba(245, 158, 11, 0.18);
  }

  .stask-badge--failed {
    background: rgba(239, 68, 68, 0.1);
    color: rgba(239, 68, 68, 0.85);
    border-color: rgba(239, 68, 68, 0.18);
  }

  .stask-run-dots {
    display: flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
    padding: 4px 0;
  }

  .stask-run-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    transition: transform 0.15s;
  }

  .stask-run-dot:hover {
    transform: scale(1.4);
  }

  .stask-actions {
    display: flex;
    align-items: center;
    gap: 3px;
    flex-shrink: 0;
    opacity: 0;
    transition: opacity 0.15s;
  }

  .stask-card:hover .stask-actions {
    opacity: 1;
  }

  .stask-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    border-radius: var(--radius-sm);
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.07);
    color: rgba(255, 255, 255, 0.35);
    transition: all 0.15s;
    flex-shrink: 0;
  }

  .stask-btn:hover {
    background: rgba(255, 255, 255, 0.06);
    color: rgba(255, 255, 255, 0.7);
    border-color: rgba(255, 255, 255, 0.14);
  }

  .stask-btn--run:hover {
    background: rgba(59, 130, 246, 0.1);
    color: rgba(59, 130, 246, 0.8);
    border-color: rgba(59, 130, 246, 0.2);
  }

  .stask-btn--resume:hover {
    background: rgba(34, 197, 94, 0.1);
    color: rgba(34, 197, 94, 0.8);
    border-color: rgba(34, 197, 94, 0.2);
  }

  .stask-btn--delete:hover {
    background: rgba(239, 68, 68, 0.1);
    color: rgba(239, 68, 68, 0.8);
    border-color: rgba(239, 68, 68, 0.2);
  }

  .stask-description {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    line-height: 1.4;
    padding: 0 2px;
  }

  .stask-error {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 10px;
    background: rgba(239, 68, 68, 0.06);
    border: 1px solid rgba(239, 68, 68, 0.12);
    border-radius: var(--radius-sm);
    min-width: 0;
  }

  .stask-error-label {
    font-size: 0.6rem;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: rgba(239, 68, 68, 0.7);
    flex-shrink: 0;
  }

  .stask-error-text {
    font-size: 0.75rem;
    font-family: var(--font-mono);
    color: rgba(239, 68, 68, 0.7);
    min-width: 0;
  }

  .stask-meta {
    display: flex;
    gap: 0;
    background: rgba(255, 255, 255, 0.025);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-sm);
    overflow: hidden;
  }

  .stask-meta-item {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 7px 10px;
    border-right: 1px solid rgba(255, 255, 255, 0.04);
  }

  .stask-meta-item:last-child {
    border-right: none;
  }

  .stask-meta-label {
    font-size: 0.6rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .stask-meta-value {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
  }

  .stask-meta-value--mono {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
  }

  .stask-schedule {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: var(--text-secondary);
    font-weight: 500;
  }
</style>
