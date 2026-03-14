<script lang="ts">
  import type { ScheduledRun, ScheduledRunStatus } from '$lib/api/types';
  import { scheduledTasksStore } from '$lib/stores/scheduledTasks.svelte';

<<<<<<< HEAD
  interface Props {
    onSelectRun?: (run: ScheduledRun) => void;
  }

=======
  interface Props { onSelectRun?: (run: ScheduledRun) => void; }
>>>>>>> ws11/projects-goals
  let { onSelectRun }: Props = $props();

  const runs = $derived(scheduledTasksStore.filteredRuns);
  const loading = $derived(scheduledTasksStore.runsLoading);
  const total = $derived(scheduledTasksStore.runsTotal);
  const page = $derived(scheduledTasksStore.runsPage);
  const filter = $derived(scheduledTasksStore.runsFilter);
  const totalPages = $derived(Math.max(1, Math.ceil(total / 20)));

<<<<<<< HEAD
  const STATUS_FILTERS: { id: ScheduledRunStatus | 'all'; label: string }[] = [
    { id: 'all',       label: 'All' },
    { id: 'succeeded', label: 'Succeeded' },
    { id: 'failed',    label: 'Failed' },
    { id: 'timed_out', label: 'Timed Out' },
  ];

  function statusColor(status: ScheduledRunStatus): string {
    switch (status) {
      case 'succeeded': return 'rgba(34, 197, 94, 0.85)';
      case 'failed':    return 'rgba(239, 68, 68, 0.85)';
      case 'running':   return 'rgba(245, 158, 11, 0.85)';
      case 'timed_out': return 'rgba(239, 68, 68, 0.6)';
      case 'cancelled': return 'rgba(255, 255, 255, 0.4)';
      default:          return 'rgba(255, 255, 255, 0.5)';
    }
  }

  function formatDuration(ms?: number): string {
    if (!ms) return '—';
    if (ms < 1000) return `${ms}ms`;
    const s = Math.floor(ms / 1000);
    if (s < 60) return `${s}s`;
    return `${Math.floor(s / 60)}m ${s % 60}s`;
  }

  function formatTime(iso: string): string {
    const d = new Date(iso);
    const now = new Date();
    const diff = now.getTime() - d.getTime();
    if (diff < 86400000) {
      return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
    }
    return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  }
</script>

<div class="run-history">
  <!-- Filter bar -->
  <div class="rh-filter-bar">
    <div class="rh-filters" role="group" aria-label="Filter runs by status">
      {#each STATUS_FILTERS as sf}
        <button
          class="rh-filter-btn"
          class:rh-filter-btn--active={filter === sf.id}
          onclick={() => scheduledTasksStore.setRunsFilter(sf.id)}
          aria-pressed={filter === sf.id}
        >
          {sf.label}
        </button>
      {/each}
    </div>
  </div>

  {#if loading}
    <div class="rh-loading" role="status">
      <span class="rh-spinner" aria-hidden="true"></span>
      Loading runs...
    </div>
  {:else if runs.length === 0}
    <div class="rh-empty" role="status">
      <p class="rh-empty-title">No runs yet</p>
      <p class="rh-empty-subtitle">Trigger a manual run to get started.</p>
    </div>
  {:else}
    <!-- Table -->
    <div class="rh-table-wrap">
      <table class="rh-table" aria-label="Run history">
        <thead>
          <tr>
            <th>Status</th>
            <th>Started</th>
            <th>Duration</th>
            <th>Trigger</th>
            <th>Agent</th>
          </tr>
        </thead>
        <tbody>
          {#each runs as run (run.id)}
            <tr
              class="rh-row"
              onclick={() => onSelectRun?.(run)}
              role="button"
              tabindex="0"
              onkeydown={(e) => { if (e.key === 'Enter') onSelectRun?.(run); }}
            >
              <td>
                <span class="rh-status" style="color: {statusColor(run.status)}; border-color: {statusColor(run.status)}">
                  {run.status}
                </span>
              </td>
              <td class="rh-time">{formatTime(run.started_at)}</td>
              <td class="rh-duration">{formatDuration(run.duration_ms)}</td>
              <td class="rh-trigger">{run.trigger_type}</td>
=======
  const STATUSES: { id: ScheduledRunStatus | 'all'; label: string }[] = [
    { id: 'all', label: 'All' }, { id: 'succeeded', label: 'Succeeded' }, { id: 'failed', label: 'Failed' }, { id: 'timed_out', label: 'Timed Out' },
  ];

  function statusClr(s: ScheduledRunStatus): string { switch (s) { case 'succeeded': return 'rgba(34,197,94,0.85)'; case 'failed': return 'rgba(239,68,68,0.85)'; case 'running': return 'rgba(245,158,11,0.85)'; default: return 'rgba(255,255,255,0.5)'; } }
  function fmtDur(ms?: number): string { if (!ms) return '—'; if (ms < 1000) return `${ms}ms`; const s = Math.floor(ms / 1000); if (s < 60) return `${s}s`; return `${Math.floor(s / 60)}m ${s % 60}s`; }
  function fmtTime(iso: string): string { const d = new Date(iso); if (Date.now() - d.getTime() < 86400000) return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' }); return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); }
</script>

<div class="rh">
  <div class="rh-bar">
    <div class="rh-filters" role="group" aria-label="Filter runs">
      {#each STATUSES as sf}<button class="rh-fbtn" class:rh-fbtn--on={filter === sf.id} onclick={() => scheduledTasksStore.setRunsFilter(sf.id)} aria-pressed={filter === sf.id}>{sf.label}</button>{/each}
    </div>
  </div>
  {#if loading}<div class="rh-loading" role="status"><span class="rh-spin" aria-hidden="true"></span> Loading runs...</div>
  {:else if runs.length === 0}<div class="rh-empty" role="status"><p class="rh-empty-title">No runs yet</p><p class="rh-empty-sub">Trigger a manual run to get started.</p></div>
  {:else}
    <div class="rh-wrap">
      <table class="rh-table" aria-label="Run history">
        <thead><tr><th>Status</th><th>Started</th><th>Duration</th><th>Trigger</th><th>Agent</th></tr></thead>
        <tbody>
          {#each runs as run (run.id)}
            <tr class="rh-row" onclick={() => onSelectRun?.(run)} role="button" tabindex="0" onkeydown={(e) => { if (e.key === 'Enter') onSelectRun?.(run); }}>
              <td><span class="rh-status" style="color:{statusClr(run.status)};border-color:{statusClr(run.status)}">{run.status}</span></td>
              <td class="rh-time">{fmtTime(run.started_at)}</td>
              <td class="rh-dur">{fmtDur(run.duration_ms)}</td>
              <td class="rh-trig">{run.trigger_type}</td>
>>>>>>> ws11/projects-goals
              <td class="rh-agent">{run.agent_name}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
<<<<<<< HEAD

    <!-- Pagination -->
    {#if totalPages > 1}
      <div class="rh-pagination">
        <button
          class="rh-page-btn"
          disabled={page <= 1}
          onclick={() => scheduledTasksStore.fetchRuns(undefined, page - 1)}
        >
          Prev
        </button>
        <span class="rh-page-info">{page} / {totalPages}</span>
        <button
          class="rh-page-btn"
          disabled={page >= totalPages}
          onclick={() => scheduledTasksStore.fetchRuns(undefined, page + 1)}
        >
          Next
        </button>
      </div>
=======
    {#if totalPages > 1}
      <div class="rh-pag"><button class="rh-pbtn" disabled={page <= 1} onclick={() => scheduledTasksStore.fetchRuns(undefined, page - 1)}>Prev</button><span class="rh-pinfo">{page} / {totalPages}</span><button class="rh-pbtn" disabled={page >= totalPages} onclick={() => scheduledTasksStore.fetchRuns(undefined, page + 1)}>Next</button></div>
>>>>>>> ws11/projects-goals
    {/if}
  {/if}
</div>

<style>
<<<<<<< HEAD
  .run-history {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .rh-filter-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .rh-filters {
    display: flex;
    gap: 4px;
  }

  .rh-filter-btn {
    padding: 5px 12px;
    border-radius: var(--radius-sm);
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.06);
    color: var(--text-tertiary);
    font-size: 0.75rem;
    font-weight: 500;
    transition: all 0.15s;
  }

  .rh-filter-btn:hover:not(.rh-filter-btn--active) {
    color: var(--text-secondary);
    border-color: rgba(255, 255, 255, 0.12);
  }

  .rh-filter-btn--active {
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-primary);
    border-color: rgba(255, 255, 255, 0.14);
  }

  .rh-loading {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 48px 0;
    color: var(--text-tertiary);
    font-size: 0.8125rem;
  }

  .rh-spinner {
    display: block;
    width: 14px;
    height: 14px;
    border: 2px solid rgba(255, 255, 255, 0.08);
    border-top-color: rgba(255, 255, 255, 0.4);
    border-radius: 50%;
    animation: rh-spin 0.8s linear infinite;
  }

  @keyframes rh-spin {
    to { transform: rotate(360deg); }
  }

  .rh-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 48px 16px;
    gap: 6px;
  }

  .rh-empty-title {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .rh-empty-subtitle {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
  }

  .rh-table-wrap {
    overflow-x: auto;
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-sm);
  }

  .rh-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.75rem;
  }

  .rh-table th {
    padding: 8px 12px;
    text-align: left;
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
    background: rgba(255, 255, 255, 0.03);
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  }

  .rh-row {
    cursor: pointer;
    transition: background 0.1s;
  }

  .rh-row:hover {
    background: rgba(255, 255, 255, 0.04);
  }

  .rh-row td {
    padding: 8px 12px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    color: var(--text-secondary);
  }

  .rh-status {
    display: inline-block;
    padding: 1px 7px;
    border-radius: var(--radius-full);
    border: 1px solid;
    font-size: 0.6rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  .rh-time {
    font-variant-numeric: tabular-nums;
  }

  .rh-duration {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
  }

  .rh-trigger {
    text-transform: capitalize;
  }

  .rh-agent {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: var(--text-tertiary);
  }

  .rh-pagination {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 12px;
  }

  .rh-page-btn {
    padding: 5px 14px;
    border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
    color: var(--text-secondary);
    font-size: 0.75rem;
    font-weight: 500;
    transition: all 0.15s;
  }

  .rh-page-btn:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.08);
    border-color: rgba(255, 255, 255, 0.14);
  }

  .rh-page-btn:disabled {
    opacity: 0.4;
    cursor: default;
  }

  .rh-page-info {
    font-size: 0.75rem;
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
  }
=======
  .rh { display: flex; flex-direction: column; gap: 12px; }
  .rh-bar { display: flex; align-items: center; }
  .rh-filters { display: flex; gap: 4px; }
  .rh-fbtn { padding: 5px 12px; border-radius: var(--radius-sm); background: none; border: 1px solid rgba(255,255,255,0.06); color: var(--text-tertiary); font-size: 0.75rem; font-weight: 500; transition: all 0.15s; }
  .rh-fbtn:hover:not(.rh-fbtn--on) { color: var(--text-secondary); border-color: rgba(255,255,255,0.12); }
  .rh-fbtn--on { background: rgba(255,255,255,0.08); color: var(--text-primary); border-color: rgba(255,255,255,0.14); }
  .rh-loading { display: flex; align-items: center; justify-content: center; gap: 8px; padding: 48px 0; color: var(--text-tertiary); font-size: 0.8125rem; }
  .rh-spin { display: block; width: 14px; height: 14px; border: 2px solid rgba(255,255,255,0.08); border-top-color: rgba(255,255,255,0.4); border-radius: 50%; animation: rh-rot 0.8s linear infinite; }
  @keyframes rh-rot { to { transform: rotate(360deg); } }
  .rh-empty { display: flex; flex-direction: column; align-items: center; padding: 48px 16px; gap: 6px; }
  .rh-empty-title { font-size: 0.875rem; font-weight: 500; color: var(--text-secondary); }
  .rh-empty-sub { font-size: 0.8125rem; color: var(--text-tertiary); }
  .rh-wrap { overflow-x: auto; border: 1px solid rgba(255,255,255,0.06); border-radius: var(--radius-sm); }
  .rh-table { width: 100%; border-collapse: collapse; font-size: 0.75rem; }
  .rh-table th { padding: 8px 12px; text-align: left; font-size: 0.625rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; color: var(--text-muted); background: rgba(255,255,255,0.03); border-bottom: 1px solid rgba(255,255,255,0.06); }
  .rh-row { cursor: pointer; transition: background 0.1s; }
  .rh-row:hover { background: rgba(255,255,255,0.04); }
  .rh-row td { padding: 8px 12px; border-bottom: 1px solid rgba(255,255,255,0.04); color: var(--text-secondary); }
  .rh-status { display: inline-block; padding: 1px 7px; border-radius: var(--radius-full); border: 1px solid; font-size: 0.6rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; }
  .rh-time { font-variant-numeric: tabular-nums; }
  .rh-dur { font-family: var(--font-mono); font-size: 0.6875rem; }
  .rh-trig { text-transform: capitalize; }
  .rh-agent { font-family: var(--font-mono); font-size: 0.6875rem; color: var(--text-tertiary); }
  .rh-pag { display: flex; align-items: center; justify-content: center; gap: 12px; }
  .rh-pbtn { padding: 5px 14px; border-radius: var(--radius-sm); background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.08); color: var(--text-secondary); font-size: 0.75rem; font-weight: 500; transition: all 0.15s; }
  .rh-pbtn:hover:not(:disabled) { background: rgba(255,255,255,0.08); border-color: rgba(255,255,255,0.14); }
  .rh-pbtn:disabled { opacity: 0.4; cursor: default; }
  .rh-pinfo { font-size: 0.75rem; color: var(--text-tertiary); font-variant-numeric: tabular-nums; }
>>>>>>> ws11/projects-goals
</style>
