<script lang="ts">
  import { onMount } from 'svelte';
  import { slide } from 'svelte/transition';
  import { projectsStore } from '$lib/stores/projects.svelte';
  import type { CreateProjectPayload } from '$lib/stores/projects.svelte';
  import ProjectCard from '$lib/components/projects/ProjectCard.svelte';
  import ProjectDetail from '$lib/components/projects/ProjectDetail.svelte';

  type FilterTab = 'all' | 'active' | 'completed' | 'archived';

  const TABS: { id: FilterTab; label: string }[] = [
    { id: 'all',       label: 'All' },
    { id: 'active',    label: 'Active' },
    { id: 'completed', label: 'Completed' },
    { id: 'archived',  label: 'Archived' },
  ];

  let activeFilter = $state<FilterTab>('all');
  let showForm = $state(false);
  let formName = $state('');
  let formDesc = $state('');
  let formGoal = $state('');
  let formPath = $state('');
  let formError = $state('');

  const visibleProjects = $derived(
    activeFilter === 'all'
      ? projectsStore.projects
      : projectsStore.projects.filter(p => p.status === activeFilter)
  );

  function countFor(tab: FilterTab): number {
    if (tab === 'all') return projectsStore.projects.length;
    return projectsStore.projects.filter(p => p.status === tab).length;
  }

  onMount(() => { projectsStore.fetchProjects(); });

  function resetForm() {
    formName = ''; formDesc = ''; formGoal = ''; formPath = ''; formError = '';
    showForm = false;
  }

  async function handleCreate() {
    const name = formName.trim();
    if (!name) { formError = 'Project name is required.'; return; }
    const payload: CreateProjectPayload = { name };
    if (formDesc.trim()) payload.description = formDesc.trim();
    if (formGoal.trim()) payload.goal = formGoal.trim();
    if (formPath.trim()) payload.workspace_path = formPath.trim();
    await projectsStore.createProject(payload);
    resetForm();
  }

  function handleSelect(id: number) {
    projectsStore.selectProject(id);
  }

  function handleBack() {
    projectsStore.clearSelection();
  }
</script>

{#if projectsStore.selectedProject}
  <ProjectDetail project={projectsStore.selectedProject} onBack={handleBack} />
{:else}
  <div class="projects-page">
    <header class="page-header">
      <div class="header-left">
        <h1 class="page-title">Projects</h1>
        <span class="page-subtitle">Organize work with goals and tasks</span>
      </div>
      <div class="header-right">
        {#if projectsStore.projects.length > 0}
          <div class="stats-bar" role="status" aria-label="Project statistics">
            <span class="stat stat--active">
              <span class="stat-dot stat-dot--active" aria-hidden="true"></span>
              <span class="stat-value">{projectsStore.activeCount}</span>
              <span class="stat-label">active</span>
            </span>
            {#if projectsStore.completedCount > 0}
              <span class="stat-divider" aria-hidden="true"></span>
              <span class="stat">
                <span class="stat-value">{projectsStore.completedCount}</span>
                <span class="stat-label">completed</span>
              </span>
            {/if}
          </div>
        {/if}
        <button class="new-btn" onclick={() => { showForm = true; }} aria-label="Create new project" aria-expanded={showForm}>
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true">
            <line x1="6" y1="1" x2="6" y2="11"/>
            <line x1="1" y1="6" x2="11" y2="6"/>
          </svg>
          New Project
        </button>
      </div>
    </header>

    <nav class="filter-nav" aria-label="Filter projects by status">
      {#each TABS as tab}
        <button
          class="filter-tab"
          class:filter-tab--active={activeFilter === tab.id}
          onclick={() => { activeFilter = tab.id; }}
          aria-pressed={activeFilter === tab.id}
        >
          {tab.label}
          {#if countFor(tab.id) > 0}
            <span class="filter-tab-count" aria-hidden="true">{countFor(tab.id)}</span>
          {/if}
        </button>
      {/each}
    </nav>

    <main class="page-content">
      {#if showForm}
        <div transition:slide={{ duration: 180 }} class="form-wrapper">
          <div class="create-form">
            <input class="form-input" type="text" bind:value={formName} placeholder="Project name *" aria-label="Project name" aria-required="true" />
            <input class="form-input" type="text" bind:value={formDesc} placeholder="Description" aria-label="Description" />
            <input class="form-input" type="text" bind:value={formGoal} placeholder="Top-level goal" aria-label="Goal" />
            <input class="form-input" type="text" bind:value={formPath} placeholder="Workspace path" aria-label="Workspace path" />
            {#if formError}
              <span class="form-error" role="alert">{formError}</span>
            {/if}
            <div class="form-actions">
              <button class="form-cancel" onclick={resetForm}>Cancel</button>
              <button class="form-submit" onclick={handleCreate}>Create Project</button>
            </div>
          </div>
        </div>
      {/if}

      {#if projectsStore.loading && projectsStore.projects.length === 0}
        <div class="empty-state" role="status" aria-label="Loading projects">
          <span class="loading-spinner" aria-hidden="true"></span>
          <p class="empty-title">Loading projects</p>
        </div>
      {:else if visibleProjects.length === 0}
        <div class="empty-state" role="status">
          <div class="empty-icon" aria-hidden="true">
            <svg width="44" height="44" viewBox="0 0 44 44" fill="none" xmlns="http://www.w3.org/2000/svg">
              <rect x="6" y="10" width="32" height="24" rx="3" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.3"/>
              <path d="M6 16h13l2-6h10l2 6h5" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.5"/>
            </svg>
          </div>
          {#if activeFilter === 'all'}
            <p class="empty-title">No projects yet</p>
            <p class="empty-subtitle">Create a project to organize tasks and track goals.</p>
            <button class="empty-cta" onclick={() => { showForm = true; }}>Create your first project</button>
          {:else}
            <p class="empty-title">No {activeFilter} projects</p>
            <p class="empty-subtitle">No projects match the "{activeFilter}" filter.</p>
          {/if}
        </div>
      {:else}
        <div class="project-grid" role="list" aria-label="Projects">
          {#each visibleProjects as project (project.id)}
            <div role="listitem">
              <ProjectCard {project} onSelect={handleSelect} />
            </div>
          {/each}
        </div>
      {/if}
    </main>
  </div>
{/if}

<style>
  .projects-page {
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

  .header-left { display: flex; flex-direction: column; gap: 2px; }

  .page-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.01em;
  }

  .page-subtitle { font-size: 0.75rem; color: var(--text-tertiary); }

  .header-right { display: flex; align-items: center; gap: 12px; }

  .stats-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    padding: 5px 14px;
  }

  .stat { display: flex; align-items: center; gap: 5px; }
  .stat--active .stat-value { color: var(--accent-success); }

  .stat-dot {
    width: 6px; height: 6px; border-radius: 50%;
    background: var(--text-tertiary);
  }

  .stat-dot--active {
    background: var(--accent-success);
    animation: pulse-proj 2s ease-in-out infinite;
  }

  @keyframes pulse-proj {
    0%, 100% { opacity: 1; transform: scale(1); }
    50% { opacity: 0.6; transform: scale(0.8); }
  }

  .stat-value {
    font-size: 0.8125rem; font-weight: 600;
    color: var(--text-primary); font-variant-numeric: tabular-nums;
  }

  .stat-label {
    font-size: 0.6875rem; color: var(--text-tertiary);
    text-transform: uppercase; letter-spacing: 0.05em;
  }

  .stat-divider { width: 1px; height: 12px; background: rgba(255, 255, 255, 0.08); }

  .new-btn {
    display: flex; align-items: center; gap: 7px;
    padding: 7px 16px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    font-size: 0.8125rem; font-weight: 500;
    transition: background 0.15s, border-color 0.15s;
    flex-shrink: 0;
  }

  .new-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
  }

  .filter-nav {
    display: flex; align-items: center; gap: 2px;
    padding: 10px 24px 0;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
  }

  .filter-tab {
    display: flex; align-items: center; gap: 6px;
    padding: 7px 14px;
    border-radius: var(--radius-sm) var(--radius-sm) 0 0;
    background: none; border: none;
    color: var(--text-tertiary);
    font-size: 0.8125rem; font-weight: 500;
    transition: color 0.15s, background 0.15s;
    position: relative; bottom: -1px;
  }

  .filter-tab:hover:not(.filter-tab--active) {
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.04);
  }

  .filter-tab--active {
    color: var(--text-primary);
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-bottom-color: var(--bg-secondary);
  }

  .filter-tab-count {
    display: inline-flex; align-items: center; justify-content: center;
    min-width: 18px; height: 18px; padding: 0 5px;
    background: rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-full);
    font-size: 0.625rem; font-weight: 600;
    color: var(--text-tertiary); font-variant-numeric: tabular-nums;
  }

  .filter-tab--active .filter-tab-count {
    background: rgba(255, 255, 255, 0.12);
    color: var(--text-secondary);
  }

  .page-content {
    flex: 1; overflow-y: auto;
    padding: 20px 24px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
    display: flex; flex-direction: column; gap: 16px;
  }

  .form-wrapper { margin-bottom: 4px; }

  .create-form {
    display: flex; flex-direction: column; gap: 8px;
    padding: 16px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-md);
  }

  .form-input {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: var(--radius-sm);
    padding: 8px 12px;
    font-size: 0.8125rem;
    color: var(--text-primary);
    outline: none; width: 100%;
    transition: border-color 0.15s;
  }

  .form-input::placeholder { color: var(--text-muted); }
  .form-input:focus { border-color: rgba(255, 255, 255, 0.18); }
  .form-error { font-size: 0.7rem; color: rgba(239, 68, 68, 0.85); }
  .form-actions { display: flex; gap: 8px; justify-content: flex-end; }

  .form-cancel {
    padding: 6px 14px; border-radius: var(--radius-sm);
    background: none; border: 1px solid rgba(255, 255, 255, 0.08);
    color: var(--text-secondary); font-size: 0.8125rem; font-weight: 500;
    transition: background 0.12s;
  }

  .form-cancel:hover { background: rgba(255, 255, 255, 0.05); }

  .form-submit {
    padding: 6px 16px; border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.14);
    color: var(--text-primary); font-size: 0.8125rem; font-weight: 600;
    transition: background 0.12s;
  }

  .form-submit:hover { background: rgba(255, 255, 255, 0.15); }

  .project-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 10px;
    align-content: start;
  }

  @media (max-width: 720px) { .project-grid { grid-template-columns: 1fr; } }

  .empty-state {
    display: flex; flex-direction: column;
    align-items: center; justify-content: center;
    min-height: 300px; gap: 10px;
    color: var(--text-tertiary); text-align: center;
    padding: 48px 32px;
  }

  .empty-icon { color: rgba(255, 255, 255, 0.1); margin-bottom: 8px; }
  .empty-title { font-size: 0.9375rem; font-weight: 500; color: var(--text-secondary); }

  .empty-subtitle {
    font-size: 0.8125rem; color: var(--text-tertiary);
    max-width: 300px; line-height: 1.55;
  }

  .empty-cta {
    margin-top: 8px; padding: 8px 20px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-sm);
    color: var(--text-primary); font-size: 0.8125rem; font-weight: 500;
    transition: background 0.15s, border-color 0.15s;
  }

  .empty-cta:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
  }

  .loading-spinner {
    display: block; width: 16px; height: 16px;
    border: 2px solid rgba(255, 255, 255, 0.08);
    border-top-color: rgba(255, 255, 255, 0.4);
    border-radius: 50%;
    animation: spin-proj 0.8s linear infinite;
    margin-bottom: 4px;
  }

  @keyframes spin-proj { to { transform: rotate(360deg); } }
</style>
