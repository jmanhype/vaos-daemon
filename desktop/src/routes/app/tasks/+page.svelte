<script lang="ts">
  import { onMount } from 'svelte';
  import { slide } from 'svelte/transition';
  import { scheduledTasksStore } from '$lib/stores/scheduledTasks.svelte';
  import ScheduledTaskCard from '$lib/components/tasks/ScheduledTaskCard.svelte';
  import ScheduledTaskForm from '$lib/components/tasks/ScheduledTaskForm.svelte';
  import RunHistory from '$lib/components/tasks/RunHistory.svelte';
  import RunDetail from '$lib/components/tasks/RunDetail.svelte';
  import type { ScheduledTask } from '$lib/stores/scheduledTasks.svelte';
  import type { ScheduledRun } from '$lib/api/types';

  type PageTab = 'scheduled' | 'history';
  type FilterTab = 'all' | 'active' | 'paused' | 'failed';
  const FILTERS: { id: FilterTab; label: string }[] = [
    { id: 'all', label: 'All' }, { id: 'active', label: 'Active' }, { id: 'paused', label: 'Paused' }, { id: 'failed', label: 'Failed' },
  ];

  let activeTab = $state<PageTab>('scheduled');
  let activeFilter = $state<FilterTab>('all');
  let showForm = $state(false);
  let editingTask = $state<ScheduledTask | null>(null);

  const visibleTasks = $derived(activeFilter === 'all' ? scheduledTasksStore.tasks : scheduledTasksStore.tasks.filter((t) => t.status === activeFilter));
  function countFor(tab: FilterTab): number { return tab === 'all' ? scheduledTasksStore.tasks.length : scheduledTasksStore.tasks.filter((t) => t.status === tab).length; }

  onMount(() => { scheduledTasksStore.fetchTasks(); scheduledTasksStore.fetchPresets(); });

  function openNewForm() { editingTask = null; showForm = true; }
  function openEditForm(id: string) { editingTask = scheduledTasksStore.tasks.find((t) => t.id === id) ?? null; showForm = true; }
  function closeForm() { showForm = false; editingTask = null; }
  async function handleSubmit(payload: Parameters<typeof scheduledTasksStore.createTask>[0]) { await scheduledTasksStore.createTask(payload); closeForm(); }
  async function handlePause(id: string) { await scheduledTasksStore.pauseTask(id); }
  async function handleResume(id: string) { await scheduledTasksStore.resumeTask(id); }
  async function handleDelete(id: string) { await scheduledTasksStore.deleteTask(id); }
  async function handleRunNow(id: string) { const run = await scheduledTasksStore.triggerNow(id); if (run?.status === 'running') scheduledTasksStore.streamRun(run.scheduled_task_id, run.id); }
  function switchToHistory() { activeTab = 'history'; scheduledTasksStore.fetchRuns(); }
  function handleSelectRun(run: ScheduledRun) { scheduledTasksStore.fetchRun(run.scheduled_task_id, run.id); if (run.status === 'running') scheduledTasksStore.streamRun(run.scheduled_task_id, run.id); }
  async function handleRerun(taskId: string) { scheduledTasksStore.closeRunDetail(); await handleRunNow(taskId); }

  const activeRunTask = $derived(scheduledTasksStore.activeRun ? scheduledTasksStore.tasks.find((t) => t.id === scheduledTasksStore.activeRun?.scheduled_task_id) : null);
</script>

<div class="tp">
  <header class="tp-header">
    <div class="tp-left"><h1 class="tp-title">Tasks</h1><span class="tp-sub">Scheduled jobs, cron automation, and run history</span></div>
    <div class="tp-right">
      {#if scheduledTasksStore.tasks.length > 0}
        <div class="tp-stats" role="status" aria-label="Stats">
          <span class="tp-stat tp-stat--ok"><span class="tp-stat-dot tp-stat-dot--ok" aria-hidden="true"></span><span class="tp-stat-val">{scheduledTasksStore.activeCount}</span><span class="tp-stat-lbl">active</span></span>
          {#if scheduledTasksStore.pausedCount > 0}<span class="tp-stat-div" aria-hidden="true"></span><span class="tp-stat"><span class="tp-stat-val">{scheduledTasksStore.pausedCount}</span><span class="tp-stat-lbl">paused</span></span>{/if}
          {#if scheduledTasksStore.failedCount > 0}<span class="tp-stat-div" aria-hidden="true"></span><span class="tp-stat tp-stat--err"><span class="tp-stat-val">{scheduledTasksStore.failedCount}</span><span class="tp-stat-lbl">failed</span></span>{/if}
        </div>
      {/if}
      {#if activeTab === 'scheduled'}
        <button class="tp-new" onclick={openNewForm} aria-label="New task" aria-expanded={showForm && !editingTask}>
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><line x1="6" y1="1" x2="6" y2="11"/><line x1="1" y1="6" x2="11" y2="6"/></svg> New Task
        </button>
      {/if}
    </div>
  </header>

  <nav class="tp-tabs" aria-label="Sections">
    <button class="tp-tab" class:tp-tab--on={activeTab === 'scheduled'} onclick={() => { activeTab = 'scheduled'; }} aria-pressed={activeTab === 'scheduled'}>Scheduled Tasks</button>
    <button class="tp-tab" class:tp-tab--on={activeTab === 'history'} onclick={switchToHistory} aria-pressed={activeTab === 'history'}>Run History</button>
  </nav>

  <main class="tp-content" id="tasks-main">
    {#if activeTab === 'scheduled'}
      <nav class="tp-filters" aria-label="Filter by status">
        {#each FILTERS as tab}<button class="tp-ftab" class:tp-ftab--on={activeFilter === tab.id} onclick={() => { activeFilter = tab.id; }} aria-pressed={activeFilter === tab.id}>{tab.label}{#if countFor(tab.id) > 0}<span class="tp-ftab-ct" aria-hidden="true">{countFor(tab.id)}</span>{/if}</button>{/each}
      </nav>
      {#if showForm}<div transition:slide={{ duration: 180 }} class="tp-form-wrap"><ScheduledTaskForm task={editingTask} onSubmit={handleSubmit} onCancel={closeForm} /></div>{/if}
      {#if scheduledTasksStore.loading && !scheduledTasksStore.tasks.length}<div class="tp-empty" role="status"><span class="tp-spinner" aria-hidden="true"></span><p class="tp-empty-title">Loading tasks</p></div>
      {:else if !visibleTasks.length}
        <div class="tp-empty" role="status">
          <div class="tp-empty-icon" aria-hidden="true"><svg width="44" height="44" viewBox="0 0 44 44" fill="none"><rect x="6" y="8" width="32" height="28" rx="4" stroke="currentColor" stroke-width="1.5" opacity="0.3"/><circle cx="22" cy="22" r="7" stroke="currentColor" stroke-width="1.5" opacity="0.5"/><line x1="22" y1="15" x2="22" y2="22" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.7"/><line x1="22" y1="22" x2="26" y2="25" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.7"/></svg></div>
          {#if activeFilter === 'all'}<p class="tp-empty-title">No scheduled tasks</p><p class="tp-empty-sub">Create a task to automate recurring jobs.</p><button class="tp-empty-cta" onclick={openNewForm}>Create your first task</button>
          {:else}<p class="tp-empty-title">No {activeFilter} tasks</p><p class="tp-empty-sub">No tasks match the "{activeFilter}" filter.</p>{/if}
        </div>
      {:else}
        <div class="tp-list" role="list" aria-label="Scheduled tasks">
          {#each visibleTasks as task (task.id)}<div role="listitem"><ScheduledTaskCard {task} onPause={handlePause} onResume={handleResume} onDelete={handleDelete} onEdit={openEditForm} onRunNow={handleRunNow} /></div>{/each}
        </div>
      {/if}
    {:else if activeTab === 'history'}
      {#if scheduledTasksStore.activeRun}<div transition:slide={{ duration: 180 }}><RunDetail run={scheduledTasksStore.activeRun} taskName={activeRunTask?.name} onClose={() => scheduledTasksStore.closeRunDetail()} onRerun={handleRerun} /></div>{/if}
      <RunHistory onSelectRun={handleSelectRun} />
    {/if}
  </main>
</div>

<style>
  .tp { display: flex; flex-direction: column; height: 100%; overflow: hidden; background: var(--bg-secondary); }
  .tp-header { display: flex; align-items: center; justify-content: space-between; padding: 20px 24px 16px; border-bottom: 1px solid rgba(255,255,255,0.05); flex-shrink: 0; gap: 16px; flex-wrap: wrap; }
  .tp-left { display: flex; flex-direction: column; gap: 2px; }
  .tp-title { font-size: 1.125rem; font-weight: 600; color: var(--text-primary); letter-spacing: -0.01em; }
  .tp-sub { font-size: 0.75rem; color: var(--text-tertiary); }
  .tp-right { display: flex; align-items: center; gap: 12px; }
  .tp-stats { display: flex; align-items: center; gap: 10px; background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.06); border-radius: var(--radius-full); padding: 5px 14px; }
  .tp-stat { display: flex; align-items: center; gap: 5px; }
  .tp-stat--ok .tp-stat-val { color: var(--accent-success); }
  .tp-stat--err .tp-stat-val { color: var(--accent-error); }
  .tp-stat-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--text-tertiary); }
  .tp-stat-dot--ok { background: var(--accent-success); animation: tp-pulse 2s ease-in-out infinite; }
  @keyframes tp-pulse { 0%,100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.6; transform: scale(0.8); } }
  .tp-stat-val { font-size: 0.8125rem; font-weight: 600; color: var(--text-primary); font-variant-numeric: tabular-nums; }
  .tp-stat-lbl { font-size: 0.6875rem; color: var(--text-tertiary); text-transform: uppercase; letter-spacing: 0.05em; }
  .tp-stat-div { width: 1px; height: 12px; background: rgba(255,255,255,0.08); }
  .tp-new { display: flex; align-items: center; gap: 7px; padding: 7px 16px; background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.12); border-radius: var(--radius-sm); color: var(--text-primary); font-size: 0.8125rem; font-weight: 500; transition: background 0.15s, border-color 0.15s; flex-shrink: 0; }
  .tp-new:hover { background: rgba(255,255,255,0.12); border-color: rgba(255,255,255,0.2); }
  .tp-tabs { display: flex; padding: 0 24px; border-bottom: 1px solid rgba(255,255,255,0.05); flex-shrink: 0; }
  .tp-tab { padding: 10px 18px; background: none; border: none; border-bottom: 2px solid transparent; color: var(--text-tertiary); font-size: 0.8125rem; font-weight: 500; transition: color 0.15s, border-color 0.15s; }
  .tp-tab:hover:not(.tp-tab--on) { color: var(--text-secondary); }
  .tp-tab--on { color: var(--text-primary); border-bottom-color: var(--text-primary); }
  .tp-filters { display: flex; gap: 4px; margin-bottom: 4px; }
  .tp-ftab { display: flex; align-items: center; gap: 6px; padding: 5px 12px; border-radius: var(--radius-sm); background: none; border: 1px solid transparent; color: var(--text-tertiary); font-size: 0.75rem; font-weight: 500; transition: color 0.15s, background 0.15s; }
  .tp-ftab:hover:not(.tp-ftab--on) { color: var(--text-secondary); background: rgba(255,255,255,0.04); }
  .tp-ftab--on { color: var(--text-primary); background: rgba(255,255,255,0.06); border-color: rgba(255,255,255,0.1); }
  .tp-ftab-ct { display: inline-flex; align-items: center; justify-content: center; min-width: 18px; height: 18px; padding: 0 5px; background: rgba(255,255,255,0.08); border-radius: var(--radius-full); font-size: 0.625rem; font-weight: 600; color: var(--text-tertiary); font-variant-numeric: tabular-nums; }
  .tp-ftab--on .tp-ftab-ct { background: rgba(255,255,255,0.12); color: var(--text-secondary); }
  .tp-content { flex: 1; overflow-y: auto; padding: 16px 24px 24px; scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.08) transparent; display: flex; flex-direction: column; gap: 12px; }
  .tp-form-wrap { margin-bottom: 4px; }
  .tp-list { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; align-content: start; }
  @media (max-width: 720px) { .tp-list { grid-template-columns: 1fr; } }
  .tp-empty { display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 300px; gap: 10px; color: var(--text-tertiary); text-align: center; padding: 48px 32px; }
  .tp-empty-icon { color: rgba(255,255,255,0.1); margin-bottom: 8px; }
  .tp-empty-title { font-size: 0.9375rem; font-weight: 500; color: var(--text-secondary); }
  .tp-empty-sub { font-size: 0.8125rem; color: var(--text-tertiary); max-width: 300px; line-height: 1.55; }
  .tp-empty-cta { margin-top: 8px; padding: 8px 20px; background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.12); border-radius: var(--radius-sm); color: var(--text-primary); font-size: 0.8125rem; font-weight: 500; transition: background 0.15s, border-color 0.15s; }
  .tp-empty-cta:hover { background: rgba(255,255,255,0.12); border-color: rgba(255,255,255,0.2); }
  .tp-spinner { display: block; width: 16px; height: 16px; border: 2px solid rgba(255,255,255,0.08); border-top-color: rgba(255,255,255,0.4); border-radius: 50%; animation: tp-spin 0.8s linear infinite; margin-bottom: 4px; }
  @keyframes tp-spin { to { transform: rotate(360deg); } }
</style>
