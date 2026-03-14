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
    switch (status) { case 'succeeded': return 'var(--accent-success)'; case 'failed': return 'var(--accent-error)'; case 'running': return 'var(--accent-warning)'; default: return 'rgba(255,255,255,0.2)'; }
  }

  const isActive = $derived(task.status === 'active');
  const isPaused = $derived(task.status === 'paused');
  const isFailed = $derived(task.status === 'failed');
  const recentRuns = $derived((task.recent_runs ?? []).slice(0, 5));
</script>

<article class="sc" class:sc--active={isActive} class:sc--paused={isPaused} class:sc--failed={isFailed} aria-label="Scheduled task: {task.name}">
  <div class="sc-header">
    <div class="sc-left">
      <span class="sc-dot" class:sc-dot--active={isActive} class:sc-dot--paused={isPaused} class:sc-dot--failed={isFailed} aria-hidden="true"></span>
      <div class="sc-id">
        <h3 class="sc-name">{task.name}</h3>
        <span class="sc-badge" class:sc-badge--active={isActive} class:sc-badge--paused={isPaused} class:sc-badge--failed={isFailed}>{statusLabel(task.status)}</span>
      </div>
    </div>
    {#if recentRuns.length > 0}
      <div class="sc-runs" aria-label="Recent runs">
        {#each recentRuns as run}<span class="sc-run-dot" style="background:{runDotColor(run.status)}" title="{run.status} — {formatRelative(run.started_at)}"></span>{/each}
      </div>
    {/if}
    <div class="sc-actions" role="group" aria-label="Actions">
      {#if onRunNow}<button class="sc-btn sc-btn--run" onclick={() => onRunNow?.(task.id)} title="Run Now"><svg width="11" height="11" viewBox="0 0 11 11" fill="currentColor" aria-hidden="true"><polygon points="2,1 10,5.5 2,10"/></svg></button>{/if}
      {#if isActive}<button class="sc-btn sc-btn--pause" onclick={() => onPause?.(task.id)} title="Pause"><svg width="11" height="11" viewBox="0 0 11 11" fill="currentColor" aria-hidden="true"><rect x="1.5" y="1" width="3" height="9" rx="1"/><rect x="6.5" y="1" width="3" height="9" rx="1"/></svg></button>
      {:else if isPaused}<button class="sc-btn sc-btn--resume" onclick={() => onResume?.(task.id)} title="Resume"><svg width="11" height="11" viewBox="0 0 11 11" fill="currentColor" aria-hidden="true"><polygon points="2,1 10,5.5 2,10"/></svg></button>
      {:else if isFailed}<button class="sc-btn sc-btn--resume" onclick={() => onResume?.(task.id)} title="Retry"><svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><path d="M1.5 5.5A4 4 0 0 1 9.5 3.2"/><polyline points="7.5,1.5 9.5,3.2 7.5,4.9" fill="none"/></svg></button>{/if}
      <button class="sc-btn" onclick={() => onEdit?.(task.id)} title="Edit"><svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7.5 1.5l2 2L3 10H1v-2L7.5 1.5z"/></svg></button>
      <button class="sc-btn sc-btn--del" onclick={() => onDelete?.(task.id)} title="Delete"><svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><line x1="1.5" y1="1.5" x2="8.5" y2="8.5"/><line x1="8.5" y1="1.5" x2="1.5" y2="8.5"/></svg></button>
    </div>
  </div>
  {#if task.description}<p class="sc-desc truncate" title={task.description}>{task.description}</p>{/if}
  {#if isFailed && task.last_error}<div class="sc-error" role="alert"><span class="sc-error-lbl">Last error</span><span class="sc-error-txt truncate">{task.last_error}</span></div>{/if}
  <div class="sc-meta">
    <div class="sc-meta-item"><span class="sc-meta-lbl">Schedule</span><code class="sc-sched">{task.schedule}</code></div>
    <div class="sc-meta-item"><span class="sc-meta-lbl">Last run</span><span class="sc-meta-val">{formatRelative(task.last_run)}</span></div>
    <div class="sc-meta-item"><span class="sc-meta-lbl">Next run</span><span class="sc-meta-val">{formatRelative(task.next_run)}</span></div>
    <div class="sc-meta-item"><span class="sc-meta-lbl">Runs</span><span class="sc-meta-val sc-meta-val--mono">{task.failure_count > 0 ? `${task.failure_count} fail` : '—'}</span></div>
  </div>
</article>

<style>
  .sc { background: var(--bg-surface); border: 1px solid var(--border-default); border-radius: var(--radius-md); padding: 14px 16px; display: flex; flex-direction: column; gap: 10px; transition: border-color 0.2s, box-shadow 0.2s; }
  .sc--active { border-color: rgba(34,197,94,0.18); box-shadow: 0 0 0 1px rgba(34,197,94,0.05); }
  .sc--failed { border-color: rgba(239,68,68,0.2); box-shadow: 0 0 0 1px rgba(239,68,68,0.05); }
  .sc--paused { opacity: 0.72; }
  .sc-header { display: flex; align-items: flex-start; justify-content: space-between; gap: 8px; }
  .sc-left { display: flex; align-items: center; gap: 10px; min-width: 0; flex: 1; }
  .sc-dot { display: block; width: 8px; height: 8px; border-radius: 50%; background: rgba(255,255,255,0.2); flex-shrink: 0; }
  .sc-dot--active { background: var(--accent-success); box-shadow: 0 0 6px rgba(34,197,94,0.5); animation: sc-pulse 2s ease-in-out infinite; }
  .sc-dot--paused { background: var(--accent-warning); }
  .sc-dot--failed { background: var(--accent-error); box-shadow: 0 0 5px rgba(239,68,68,0.4); }
  @keyframes sc-pulse { 0%,100% { box-shadow: 0 0 4px rgba(34,197,94,0.4); } 50% { box-shadow: 0 0 10px rgba(34,197,94,0.7); } }
  .sc-id { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .sc-name { font-size: 0.875rem; font-weight: 500; color: var(--text-primary); line-height: 1.2; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sc-badge { display: inline-flex; padding: 1px 7px; border-radius: var(--radius-full); font-size: 0.6rem; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; width: fit-content; background: rgba(255,255,255,0.07); color: var(--text-tertiary); border: 1px solid rgba(255,255,255,0.06); }
  .sc-badge--active { background: rgba(34,197,94,0.1); color: rgba(34,197,94,0.85); border-color: rgba(34,197,94,0.18); }
  .sc-badge--paused { background: rgba(245,158,11,0.1); color: rgba(245,158,11,0.85); border-color: rgba(245,158,11,0.18); }
  .sc-badge--failed { background: rgba(239,68,68,0.1); color: rgba(239,68,68,0.85); border-color: rgba(239,68,68,0.18); }
  .sc-runs { display: flex; align-items: center; gap: 4px; flex-shrink: 0; padding: 4px 0; }
  .sc-run-dot { width: 7px; height: 7px; border-radius: 50%; transition: transform 0.15s; }
  .sc-run-dot:hover { transform: scale(1.4); }
  .sc-actions { display: flex; align-items: center; gap: 3px; flex-shrink: 0; opacity: 0; transition: opacity 0.15s; }
  .sc:hover .sc-actions { opacity: 1; }
  .sc-btn { display: flex; align-items: center; justify-content: center; width: 26px; height: 26px; border-radius: var(--radius-sm); background: none; border: 1px solid rgba(255,255,255,0.07); color: rgba(255,255,255,0.35); transition: all 0.15s; flex-shrink: 0; }
  .sc-btn:hover { background: rgba(255,255,255,0.06); color: rgba(255,255,255,0.7); border-color: rgba(255,255,255,0.14); }
  .sc-btn--run:hover { background: rgba(59,130,246,0.1); color: rgba(59,130,246,0.8); border-color: rgba(59,130,246,0.2); }
  .sc-btn--resume:hover { background: rgba(34,197,94,0.1); color: rgba(34,197,94,0.8); border-color: rgba(34,197,94,0.2); }
  .sc-btn--del:hover { background: rgba(239,68,68,0.1); color: rgba(239,68,68,0.8); border-color: rgba(239,68,68,0.2); }
  .sc-desc { font-size: 0.8125rem; color: var(--text-tertiary); line-height: 1.4; padding: 0 2px; }
  .sc-error { display: flex; align-items: center; gap: 8px; padding: 6px 10px; background: rgba(239,68,68,0.06); border: 1px solid rgba(239,68,68,0.12); border-radius: var(--radius-sm); min-width: 0; }
  .sc-error-lbl { font-size: 0.6rem; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: rgba(239,68,68,0.7); flex-shrink: 0; }
  .sc-error-txt { font-size: 0.75rem; font-family: var(--font-mono); color: rgba(239,68,68,0.7); min-width: 0; }
  .sc-meta { display: flex; background: rgba(255,255,255,0.025); border: 1px solid rgba(255,255,255,0.05); border-radius: var(--radius-sm); overflow: hidden; }
  .sc-meta-item { flex: 1; display: flex; flex-direction: column; gap: 2px; padding: 7px 10px; border-right: 1px solid rgba(255,255,255,0.04); }
  .sc-meta-item:last-child { border-right: none; }
  .sc-meta-lbl { font-size: 0.6rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; color: var(--text-muted); }
  .sc-meta-val { font-size: 0.75rem; font-weight: 500; color: var(--text-secondary); font-variant-numeric: tabular-nums; }
  .sc-meta-val--mono { font-family: var(--font-mono); font-size: 0.6875rem; }
  .sc-sched { font-family: var(--font-mono); font-size: 0.6875rem; color: var(--text-secondary); font-weight: 500; }
</style>
