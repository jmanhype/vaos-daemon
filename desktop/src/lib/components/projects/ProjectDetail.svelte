<script lang="ts">
  import { slide } from 'svelte/transition';
  import { projectsStore } from '$lib/stores/projects.svelte';
  import type { Project } from '$lib/stores/projects.svelte';
  import GoalTree from './GoalTree.svelte';

  interface Props {
    project: Project;
    onBack: () => void;
  }

  let { project, onBack }: Props = $props();

  // Inline name editing
  let editingName = $state(false);
  let editName    = $state(project.name);

  // Add goal form
  let showGoalForm  = $state(false);
  let newGoalTitle  = $state('');
  let goalFormError = $state('');

  const goals       = $derived(projectsStore.goals);
  const isActive    = $derived(project.status === 'active');
  const isCompleted = $derived(project.status === 'completed');

  function saveName() {
    const trimmed = editName.trim();
    if (trimmed && trimmed !== project.name) {
      projectsStore.updateProject(project.id, { name: trimmed });
    } else {
      editName = project.name;
    }
    editingName = false;
  }

  function handleNameKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter') saveName();
    if (e.key === 'Escape') { editName = project.name; editingName = false; }
  }

  async function handleAddGoal() {
    const trimmed = newGoalTitle.trim();
    if (!trimmed) { goalFormError = 'Goal title is required.'; return; }
    await projectsStore.createGoal(project.id, { title: trimmed });
    newGoalTitle = '';
    goalFormError = '';
    showGoalForm = false;
  }

  function handleGoalFormKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter') handleAddGoal();
    if (e.key === 'Escape') { showGoalForm = false; newGoalTitle = ''; goalFormError = ''; }
  }

  function handleAddChildGoal(_parentId: number) {
    showGoalForm = true;
  }
</script>

<div class="proj-detail">

  <!-- Back header -->
  <header class="detail-header">
    <button class="back-btn" onclick={onBack} aria-label="Back to projects">
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <polyline points="9,2 4,7 9,12"/>
      </svg>
      Projects
    </button>

    <span
      class="proj-badge"
      class:proj-badge--active={isActive}
      class:proj-badge--completed={isCompleted}
      class:proj-badge--archived={project.status === 'archived'}
    >
      {project.status}
    </span>
  </header>

  <div class="detail-body">

    <!-- Title (inline-editable) -->
    <div class="name-row">
      {#if editingName}
        <input
          class="name-input"
          type="text"
          bind:value={editName}
          onblur={saveName}
          onkeydown={handleNameKeydown}
          aria-label="Edit project name"
          autofocus
        />
      {:else}
        <button
          class="name-display"
          onclick={() => { editingName = true; editName = project.name; }}
          aria-label="Click to edit project name"
          title="Click to edit"
        >
          {project.name}
        </button>
      {/if}
    </div>

    <!-- Description -->
    {#if project.description}
      <p class="detail-description">{project.description}</p>
    {/if}

    <!-- Goal -->
    {#if project.goal}
      <div class="detail-goal-block">
        <span class="detail-label">Goal</span>
        <p class="detail-goal-text">{project.goal}</p>
      </div>
    {/if}

    <!-- Workspace path -->
    {#if project.workspace_path}
      <div class="detail-workspace">
        <span class="detail-label">Workspace</span>
        <code class="workspace-path">{project.workspace_path}</code>
      </div>
    {/if}

    <!-- Stats row -->
    <div class="detail-stats">
      <div class="detail-stat">
        <span class="stat-value">{projectsStore.flatGoals.length}</span>
        <span class="stat-label">goals</span>
      </div>
      <div class="stat-sep" aria-hidden="true"></div>
      <div class="detail-stat">
        <span class="stat-value">{projectsStore.projectTasks.length}</span>
        <span class="stat-label">tasks</span>
      </div>
    </div>

    <!-- Goals section -->
    <section class="detail-section" aria-labelledby="goals-heading">
      <div class="section-header">
        <h2 class="section-title" id="goals-heading">Goals</h2>
        <button
          class="section-action-btn"
          onclick={() => { showGoalForm = !showGoalForm; }}
          aria-label="Add goal"
          aria-expanded={showGoalForm}
        >
          <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
            <line x1="5" y1="1" x2="5" y2="9"/>
            <line x1="1" y1="5" x2="9" y2="5"/>
          </svg>
          Add Goal
        </button>
      </div>

      <!-- Add goal form -->
      {#if showGoalForm}
        <div transition:slide={{ duration: 150 }} class="goal-form">
          <input
            class="goal-input"
            type="text"
            bind:value={newGoalTitle}
            placeholder="Goal title..."
            onkeydown={handleGoalFormKeydown}
            aria-label="New goal title"
            aria-describedby={goalFormError ? 'goal-form-err' : undefined}
            autofocus
          />
          {#if goalFormError}
            <span id="goal-form-err" class="goal-form-error" role="alert">{goalFormError}</span>
          {/if}
          <div class="goal-form-actions">
            <button class="goal-form-cancel" onclick={() => { showGoalForm = false; newGoalTitle = ''; goalFormError = ''; }}>
              Cancel
            </button>
            <button class="goal-form-submit" onclick={handleAddGoal}>
              Add Goal
            </button>
          </div>
        </div>
      {/if}

      <!-- Goal tree -->
      {#if goals.length > 0}
        <GoalTree nodes={goals} onAddGoal={handleAddChildGoal} />
      {:else}
        <p class="no-goals">No goals yet. Add one to get started.</p>
      {/if}
    </section>

  </div>
</div>

<style>
  .proj-detail {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  .detail-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 14px 24px 12px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
    gap: 12px;
  }

  .back-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    background: none;
    border: none;
    color: var(--text-tertiary);
    font-size: 0.8125rem;
    font-weight: 500;
    transition: color 0.12s;
    padding: 4px 0;
  }

  .back-btn:hover { color: var(--text-secondary); }

  .proj-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    border-radius: var(--radius-full);
    font-size: 0.6rem;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    background: rgba(255, 255, 255, 0.07);
    color: var(--text-tertiary);
    border: 1px solid rgba(255, 255, 255, 0.06);
  }

  .proj-badge--active    { background: rgba(34, 197, 94, 0.1); color: rgba(34, 197, 94, 0.85); border-color: rgba(34, 197, 94, 0.18); }
  .proj-badge--completed { background: rgba(59, 130, 246, 0.1); color: rgba(59, 130, 246, 0.85); border-color: rgba(59, 130, 246, 0.18); }
  .proj-badge--archived  { opacity: 0.6; }

  .detail-body {
    flex: 1;
    overflow-y: auto;
    padding: 20px 24px 24px;
    display: flex;
    flex-direction: column;
    gap: 14px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  /* ── Name ── */

  .name-row { display: flex; align-items: center; }

  .name-display {
    font-size: 1.125rem;
    font-weight: 700;
    color: var(--text-primary);
    background: none;
    border: none;
    padding: 2px 4px;
    border-radius: var(--radius-xs);
    cursor: text;
    transition: background 0.12s;
    letter-spacing: -0.01em;
    text-align: left;
  }

  .name-display:hover { background: rgba(255, 255, 255, 0.05); }

  .name-input {
    font-size: 1.125rem;
    font-weight: 700;
    color: var(--text-primary);
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.15);
    border-radius: var(--radius-xs);
    padding: 2px 8px;
    outline: none;
    width: 100%;
    letter-spacing: -0.01em;
  }

  .name-input:focus {
    border-color: var(--accent-primary);
    box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.15);
  }

  /* ── Content ── */

  .detail-description {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    line-height: 1.55;
  }

  .detail-goal-block {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 10px 12px;
    background: rgba(255, 255, 255, 0.025);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-sm);
  }

  .detail-label {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    color: var(--text-muted);
  }

  .detail-goal-text {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.5;
  }

  .detail-workspace { display: flex; flex-direction: column; gap: 4px; }

  .workspace-path {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-sm);
    padding: 4px 8px;
    display: block;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* ── Stats ── */

  .detail-stats {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 10px 14px;
    background: rgba(255, 255, 255, 0.025);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-sm);
  }

  .detail-stat {
    display: flex;
    flex-direction: column;
    gap: 1px;
    align-items: center;
  }

  .stat-value {
    font-size: 1rem;
    font-weight: 600;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
  }

  .stat-label {
    font-size: 0.6rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .stat-sep {
    width: 1px;
    height: 24px;
    background: rgba(255, 255, 255, 0.06);
  }

  /* ── Goals section ── */

  .detail-section {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .section-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }

  .section-title {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    color: var(--text-tertiary);
  }

  .section-action-btn {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 4px 10px;
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-sm);
    color: var(--text-muted);
    font-size: 0.6875rem;
    font-weight: 500;
    transition: all 0.15s;
  }

  .section-action-btn:hover {
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-secondary);
    border-color: rgba(255, 255, 255, 0.14);
  }

  /* ── Add goal form ── */

  .goal-form {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 10px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-sm);
  }

  .goal-input {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: var(--radius-sm);
    padding: 7px 10px;
    font-size: 0.8125rem;
    color: var(--text-primary);
    outline: none;
    width: 100%;
    transition: border-color 0.15s, box-shadow 0.15s;
  }

  .goal-input::placeholder { color: var(--text-muted); }

  .goal-input:focus {
    border-color: rgba(255, 255, 255, 0.18);
    box-shadow: 0 0 0 2px rgba(255, 255, 255, 0.04);
  }

  .goal-form-error {
    font-size: 0.7rem;
    color: rgba(239, 68, 68, 0.85);
  }

  .goal-form-actions {
    display: flex;
    gap: 6px;
    justify-content: flex-end;
  }

  .goal-form-cancel {
    padding: 5px 12px;
    border-radius: var(--radius-sm);
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.08);
    color: var(--text-secondary);
    font-size: 0.75rem;
    font-weight: 500;
    transition: background 0.12s, border-color 0.12s;
  }

  .goal-form-cancel:hover {
    background: rgba(255, 255, 255, 0.05);
    border-color: rgba(255, 255, 255, 0.14);
  }

  .goal-form-submit {
    padding: 5px 14px;
    border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.14);
    color: var(--text-primary);
    font-size: 0.75rem;
    font-weight: 600;
    transition: background 0.12s, border-color 0.12s;
  }

  .goal-form-submit:hover {
    background: rgba(255, 255, 255, 0.15);
    border-color: rgba(255, 255, 255, 0.22);
  }

  .no-goals {
    font-size: 0.8125rem;
    color: var(--text-muted);
    padding: 12px 0;
    text-align: center;
  }
</style>
