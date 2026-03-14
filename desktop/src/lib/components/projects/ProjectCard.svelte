<script lang="ts">
  import type { Project } from '$lib/stores/projects.svelte';

  interface Props {
    project: Project;
    goalCount?: number;
    taskCount?: number;
    onSelect?: (id: number) => void;
  }

  let { project, goalCount, taskCount, onSelect }: Props = $props();

  const goals = $derived(goalCount ?? project.goal_count ?? 0);
  const tasks = $derived(taskCount ?? project.task_count ?? 0);
  const completedGoals = $derived(project.completed_goal_count ?? 0);
  const progress = $derived(goals > 0 ? Math.round((completedGoals / goals) * 100) : 0);

  const isActive    = $derived(project.status === 'active');
  const isCompleted = $derived(project.status === 'completed');
</script>

<article
  class="proj-card"
  class:proj-card--active={isActive}
  class:proj-card--completed={isCompleted}
  aria-label="Project: {project.name}"
  role="button"
  tabindex="0"
  onclick={() => onSelect?.(project.id)}
  onkeydown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onSelect?.(project.id); } }}
>
  <!-- Header row -->
  <div class="proj-header">
    <div class="proj-identity">
      <h3 class="proj-name">{project.name}</h3>
      <span
        class="proj-badge"
        class:proj-badge--active={isActive}
        class:proj-badge--completed={isCompleted}
        class:proj-badge--archived={project.status === 'archived'}
      >
        {#if isActive}
          <span class="proj-dot proj-dot--active" aria-hidden="true"></span>
        {:else if isCompleted}
          <svg width="8" height="8" viewBox="0 0 8 8" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
            <polyline points="1.5,4 3.2,5.7 6.5,2"/>
          </svg>
        {/if}
        {project.status}
      </span>
    </div>
  </div>

  <!-- Goal text -->
  {#if project.goal}
    <p class="proj-goal" title={project.goal}>{project.goal}</p>
  {/if}

  <!-- Counts row -->
  <div class="proj-meta">
    <span class="proj-meta-item">
      <svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
        <circle cx="5.5" cy="5.5" r="4"/>
        <polyline points="3.5,5.5 5,7 7.5,4"/>
      </svg>
      {goals} goal{goals !== 1 ? 's' : ''}
    </span>
    <span class="proj-meta-divider" aria-hidden="true"></span>
    <span class="proj-meta-item">
      <svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
        <rect x="1.5" y="2" width="8" height="7" rx="1"/>
        <line x1="3.5" y1="5" x2="7.5" y2="5"/>
        <line x1="3.5" y1="7" x2="6.5" y2="7"/>
      </svg>
      {tasks} task{tasks !== 1 ? 's' : ''}
    </span>
  </div>

  <!-- Progress bar -->
  {#if goals > 0}
    <div class="proj-progress" aria-label="Goal progress: {progress}%">
      <div class="proj-progress-bar">
        <div
          class="proj-progress-fill"
          class:proj-progress-fill--complete={progress === 100}
          style="width: {progress}%"
        ></div>
      </div>
      <span class="proj-progress-label">{progress}%</span>
    </div>
  {/if}
</article>

<style>
  .proj-card {
    background: var(--bg-surface);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    cursor: pointer;
    transition: border-color 0.2s ease, box-shadow 0.2s ease, background 0.15s;
    outline: none;
  }

  .proj-card:hover {
    background: rgba(255, 255, 255, 0.04);
    border-color: rgba(255, 255, 255, 0.12);
  }

  .proj-card:focus-visible {
    border-color: var(--accent-primary);
    box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.3);
  }

  .proj-card--active {
    border-color: rgba(34, 197, 94, 0.16);
    box-shadow: 0 0 0 1px rgba(34, 197, 94, 0.04);
  }

  .proj-card--completed {
    opacity: 0.75;
  }

  .proj-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 8px;
  }

  .proj-identity {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
    flex-wrap: wrap;
  }

  .proj-name {
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text-primary);
    line-height: 1.2;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .proj-badge {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 1px 7px;
    border-radius: var(--radius-full);
    font-size: 0.6rem;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    background: rgba(255, 255, 255, 0.07);
    color: var(--text-tertiary);
    border: 1px solid rgba(255, 255, 255, 0.06);
    flex-shrink: 0;
  }

  .proj-badge--active {
    background: rgba(34, 197, 94, 0.1);
    color: rgba(34, 197, 94, 0.85);
    border-color: rgba(34, 197, 94, 0.18);
  }

  .proj-badge--completed {
    background: rgba(59, 130, 246, 0.1);
    color: rgba(59, 130, 246, 0.85);
    border-color: rgba(59, 130, 246, 0.18);
  }

  .proj-badge--archived {
    opacity: 0.6;
  }

  .proj-dot {
    display: block;
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: currentColor;
    flex-shrink: 0;
  }

  .proj-dot--active {
    animation: proj-pulse 2s ease-in-out infinite;
  }

  @keyframes proj-pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.5; }
  }

  .proj-goal {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    line-height: 1.45;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .proj-meta {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .proj-meta-item {
    display: flex;
    align-items: center;
    gap: 4px;
    font-size: 0.75rem;
    color: var(--text-muted);
    font-variant-numeric: tabular-nums;
  }

  .proj-meta-divider {
    width: 1px;
    height: 10px;
    background: rgba(255, 255, 255, 0.08);
  }

  .proj-progress {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .proj-progress-bar {
    flex: 1;
    height: 3px;
    background: rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-full);
    overflow: hidden;
  }

  .proj-progress-fill {
    height: 100%;
    background: rgba(59, 130, 246, 0.7);
    border-radius: var(--radius-full);
    transition: width 0.4s ease;
  }

  .proj-progress-fill--complete {
    background: rgba(34, 197, 94, 0.8);
  }

  .proj-progress-label {
    font-size: 0.6875rem;
    color: var(--text-muted);
    font-variant-numeric: tabular-nums;
    flex-shrink: 0;
    width: 28px;
    text-align: right;
  }

</style>
