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

  // ── Page tabs ───────────────────────────────────────────────────────────────

  type PageTab = 'scheduled' | 'history';

  let activeTab = $state<PageTab>('scheduled');

  // ── Filter tabs (within scheduled) ──────────────────────────────────────────

  type FilterTab = 'all' | 'active' | 'paused' | 'failed';

  const FILTERS: { id: FilterTab; label: string }[] = [
    { id: 'all',    label: 'All'       },
    { id: 'active', label: 'Active'    },
    { id: 'paused', label: 'Paused'    },
    { id: 'failed', label: 'Failed'    },
  ];

  // ── Local state ─────────────────────────────────────────────────────────────

  let activeFilter = $state<FilterTab>('all');
  let showForm     = $state(false);
  let editingTask  = $state<ScheduledTask | null>(null);

  const visibleTasks = $derived(
    activeFilter === 'all'
      ? scheduledTasksStore.tasks
      : scheduledTasksStore.tasks.filter((t) => t.status === activeFilter),
  );

  function countFor(tab: FilterTab): number {
    if (tab === 'all') return scheduledTasksStore.tasks.length;
    return scheduledTasksStore.tasks.filter((t) => t.status === tab).length;
  }

  // ── Mount ───────────────────────────────────────────────────────────────────

  onMount(() => {
    scheduledTasksStore.fetchTasks();
    scheduledTasksStore.fetchPresets();
  });

  // ── Handlers ────────────────────────────────────────────────────────────────

  function openNewForm() {
    editingTask = null;
    showForm = true;
  }

  function openEditForm(id: string) {
    editingTask = scheduledTasksStore.tasks.find((t) => t.id === id) ?? null;
    showForm = true;
  }

  function closeForm() {
    showForm = false;
    editingTask = null;
  }

  async function handleSubmit(payload: Parameters<typeof scheduledTasksStore.createTask>[0]) {
    await scheduledTasksStore.createTask(payload);
    closeForm();
  }

  async function handlePause(id: string) {
    await scheduledTasksStore.pauseTask(id);
  }

  async function handleResume(id: string) {
    await scheduledTasksStore.resumeTask(id);
  }

  async function handleDelete(id: string) {
    await scheduledTasksStore.deleteTask(id);
  }

  async function handleRunNow(id: string) {
    const run = await scheduledTasksStore.triggerNow(id);
    if (run && run.status === 'running') {
      scheduledTasksStore.streamRun(run.scheduled_task_id, run.id);
    }
  }

  function switchToHistory() {
    activeTab = 'history';
    scheduledTasksStore.fetchRuns();
  }

  function handleSelectRun(run: ScheduledRun) {
    scheduledTasksStore.fetchRun(run.scheduled_task_id, run.id);
    if (run.status === 'running') {
      scheduledTasksStore.streamRun(run.scheduled_task_id, run.id);
    }
  }

  function handleCloseRunDetail() {
    scheduledTasksStore.closeRunDetail();
  }

  async function handleRerun(taskId: string) {
    scheduledTasksStore.closeRunDetail();
    await handleRunNow(taskId);
  }

  const activeRunTask = $derived(
    scheduledTasksStore.activeRun
      ? scheduledTasksStore.tasks.find((t) => t.id === scheduledTasksStore.activeRun?.scheduled_task_id)
      : null
  );
</script>

<div class="tasks-page">

  <!-- Header -->
  <header class="page-header">
    <div class="header-left">
      <h1 class="page-title">Tasks</h1>
      <span class="page-subtitle">Scheduled jobs, cron automation, and run history</span>
    </div>

    <div class="header-right">
      {#if scheduledTasksStore.tasks.length > 0}
        <div class="stats-bar" role="status" aria-label="Task statistics">
          <span class="stat stat--active">
            <span class="stat-dot stat-dot--active" aria-hidden="true"></span>
            <span class="stat-value">{scheduledTasksStore.activeCount}</span>
            <span class="stat-label">active</span>
          </span>
          {#if scheduledTasksStore.pausedCount > 0}
            <span class="stat-divider" aria-hidden="true"></span>
            <span class="stat">
              <span class="stat-value">{scheduledTasksStore.pausedCount}</span>
              <span class="stat-label">paused</span>
            </span>
          {/if}
          {#if scheduledTasksStore.failedCount > 0}
            <span class="stat-divider" aria-hidden="true"></span>
            <span class="stat stat--failed">
              <span class="stat-value">{scheduledTasksStore.failedCount}</span>
              <span class="stat-label">failed</span>
            </span>
          {/if}
        </div>
      {/if}

      {#if activeTab === 'scheduled'}
        <button
          class="new-task-btn"
          onclick={openNewForm}
          aria-label="Create new scheduled task"
          aria-expanded={showForm && editingTask === null}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true">
            <line x1="6" y1="1" x2="6" y2="11"/>
            <line x1="1" y1="6" x2="11" y2="6"/>
          </svg>
          New Task
        </button>
      {/if}
    </div>
  </header>

  <!-- Page tabs -->
  <nav class="page-tabs" aria-label="Task sections">
    <button
      class="page-tab"
      class:page-tab--active={activeTab === 'scheduled'}
      onclick={() => { activeTab = 'scheduled'; }}
      aria-pressed={activeTab === 'scheduled'}
    >
      Scheduled Tasks
    </button>
    <button
      class="page-tab"
      class:page-tab--active={activeTab === 'history'}
      onclick={switchToHistory}
      aria-pressed={activeTab === 'history'}
    >
      Run History
    </button>
  </nav>

  <!-- Content -->
  <main class="page-content" id="tasks-main">

    {#if activeTab === 'scheduled'}
      <!-- Filter tabs -->
      <nav class="filter-nav" aria-label="Filter scheduled tasks by status">
        {#each FILTERS as tab}
          <button
            class="filter-tab"
            class:filter-tab--active={activeFilter === tab.id}
            onclick={() => { activeFilter = tab.id; }}
            aria-pressed={activeFilter === tab.id}
            aria-label="Show {tab.label.toLowerCase()} tasks"
          >
            {tab.label}
            {#if countFor(tab.id) > 0}
              <span class="filter-tab-count" aria-hidden="true">{countFor(tab.id)}</span>
            {/if}
          </button>
        {/each}
      </nav>

      <!-- Inline form -->
      {#if showForm}
        <div transition:slide={{ duration: 180 }} class="form-wrapper">
          <ScheduledTaskForm
            task={editingTask}
            onSubmit={handleSubmit}
            onCancel={closeForm}
          />
        </div>
      {/if}

      <!-- Loading state -->
      {#if scheduledTasksStore.loading && scheduledTasksStore.tasks.length === 0}
        <div class="empty-state" role="status" aria-label="Loading tasks">
          <span class="loading-spinner" aria-hidden="true"></span>
          <p class="empty-title">Loading tasks</p>
        </div>

      {:else if visibleTasks.length === 0}
        <div class="empty-state" role="status">
          <div class="empty-icon" aria-hidden="true">
            <svg width="44" height="44" viewBox="0 0 44 44" fill="none" xmlns="http://www.w3.org/2000/svg">
              <rect x="6" y="8" width="32" height="28" rx="4" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.3"/>
              <circle cx="22" cy="22" r="7" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.5"/>
              <line x1="22" y1="15" x2="22" y2="22" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.7"/>
              <line x1="22" y1="22" x2="26" y2="25" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.7"/>
            </svg>
          </div>
          {#if activeFilter === 'all'}
            <p class="empty-title">No scheduled tasks</p>
            <p class="empty-subtitle">
              Create a task to automate recurring jobs using cron expressions.
            </p>
            <button class="empty-cta" onclick={openNewForm} aria-label="Create first scheduled task">
              Create your first task
            </button>
          {:else}
            <p class="empty-title">No {activeFilter} tasks</p>
            <p class="empty-subtitle">No tasks match the "{activeFilter}" filter.</p>
          {/if}
        </div>

      {:else}
        <div class="task-list" role="list" aria-label="Scheduled tasks">
          {#each visibleTasks as task (task.id)}
            <div role="listitem">
              <ScheduledTaskCard
                {task}
                onPause={handlePause}
                onResume={handleResume}
                onDelete={handleDelete}
                onEdit={openEditForm}
                onRunNow={handleRunNow}
              />
            </div>
          {/each}
        </div>
      {/if}

    {:else if activeTab === 'history'}
      <!-- Run detail overlay -->
      {#if scheduledTasksStore.activeRun}
        <div transition:slide={{ duration: 180 }}>
          <RunDetail
            run={scheduledTasksStore.activeRun}
            taskName={activeRunTask?.name}
            onClose={handleCloseRunDetail}
            onRerun={handleRerun}
          />
        </div>
      {/if}

      <RunHistory onSelectRun={handleSelectRun} />
    {/if}

  </main>
</div>

<style>
  .tasks-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

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
    flex-direction: column;
    gap: 2px;
  }

  .page-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.01em;
  }

  .page-subtitle {
    font-size: 0.75rem;
    color: var(--text-tertiary);
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  /* ── Stats bar ── */

  .stats-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    padding: 5px 14px;
  }

  .stat {
    display: flex;
    align-items: center;
    gap: 5px;
  }

  .stat--active .stat-value { color: var(--accent-success); }
  .stat--failed .stat-value { color: var(--accent-error); }

  .stat-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text-tertiary);
  }

  .stat-dot--active {
    background: var(--accent-success);
    animation: pulse-stat 2s ease-in-out infinite;
  }

  @keyframes pulse-stat {
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

  .new-task-btn {
    display: flex;
    align-items: center;
    gap: 7px;
    padding: 7px 16px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    font-size: 0.8125rem;
    font-weight: 500;
    transition: background 0.15s, border-color 0.15s;
    flex-shrink: 0;
  }

  .new-task-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
  }

  /* ── Page tabs ── */

  .page-tabs {
    display: flex;
    align-items: center;
    gap: 0;
    padding: 0 24px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
  }

  .page-tab {
    padding: 10px 18px;
    background: none;
    border: none;
    border-bottom: 2px solid transparent;
    color: var(--text-tertiary);
    font-size: 0.8125rem;
    font-weight: 500;
    transition: color 0.15s, border-color 0.15s;
  }

  .page-tab:hover:not(.page-tab--active) {
    color: var(--text-secondary);
  }

  .page-tab--active {
    color: var(--text-primary);
    border-bottom-color: var(--text-primary);
  }

  /* ── Filter tabs ── */

  .filter-nav {
    display: flex;
    align-items: center;
    gap: 4px;
    margin-bottom: 4px;
  }

  .filter-tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 5px 12px;
    border-radius: var(--radius-sm);
    background: none;
    border: 1px solid transparent;
    color: var(--text-tertiary);
    font-size: 0.75rem;
    font-weight: 500;
    transition: color 0.15s, background 0.15s;
  }

  .filter-tab:hover:not(.filter-tab--active) {
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.04);
  }

  .filter-tab--active {
    color: var(--text-primary);
    background: rgba(255, 255, 255, 0.06);
    border-color: rgba(255, 255, 255, 0.1);
  }

  .filter-tab-count {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 18px;
    height: 18px;
    padding: 0 5px;
    background: rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-full);
    font-size: 0.625rem;
    font-weight: 600;
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
  }

  .filter-tab--active .filter-tab-count {
    background: rgba(255, 255, 255, 0.12);
    color: var(--text-secondary);
  }

  /* ── Content ── */

  .page-content {
    flex: 1;
    overflow-y: auto;
    padding: 16px 24px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .form-wrapper {
    margin-bottom: 4px;
  }

  .task-list {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 10px;
    align-content: start;
  }

  @media (max-width: 720px) {
    .task-list {
      grid-template-columns: 1fr;
    }
  }

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 300px;
    gap: 10px;
    color: var(--text-tertiary);
    text-align: center;
    padding: 48px 32px;
  }

  .empty-icon {
    color: rgba(255, 255, 255, 0.1);
    margin-bottom: 8px;
  }

  .empty-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .empty-subtitle {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    max-width: 300px;
    line-height: 1.55;
  }

  .empty-cta {
    margin-top: 8px;
    padding: 8px 20px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    font-size: 0.8125rem;
    font-weight: 500;
    transition: background 0.15s, border-color 0.15s;
  }

  .empty-cta:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
  }

  .loading-spinner {
    display: block;
    width: 16px;
    height: 16px;
    border: 2px solid rgba(255, 255, 255, 0.08);
    border-top-color: rgba(255, 255, 255, 0.4);
    border-radius: 50%;
    animation: spin-task 0.8s linear infinite;
    margin-bottom: 4px;
  }

  @keyframes spin-task {
    to { transform: rotate(360deg); }
  }
</style>
