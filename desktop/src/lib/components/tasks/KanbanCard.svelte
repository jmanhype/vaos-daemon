<script lang="ts">
  interface KanbanTask {
    id: number;
    task_id: string;
    status: string;
    priority: string;
    assignee_agent: string | null;
    payload: Record<string, unknown>;
    created_at: string;
  }

  interface Props {
    task: KanbanTask;
    onPriorityChange?: (taskId: number, priority: string) => void;
  }

  let { task }: Props = $props();

  const priorityColor: Record<string, string> = {
    low: 'var(--accent-success)',
    medium: '#f59e0b',
    high: '#f97316',
    critical: 'var(--accent-error)',
  };

  function handleDragStart(e: DragEvent) {
    e.dataTransfer?.setData('text/plain', String(task.id));
    if (e.dataTransfer) e.dataTransfer.effectAllowed = 'move';
  }
</script>

<article
  class="kanban-card"
  draggable="true"
  ondragstart={handleDragStart}
  aria-label="Task {task.task_id}, priority {task.priority}"
>
  <div class="card-left">
    <span
      class="priority-dot"
      style="background: {priorityColor[task.priority] ?? 'rgba(255,255,255,0.25)'};"
      aria-label="Priority: {task.priority}"
    ></span>
    <span class="task-id">{task.task_id}</span>
  </div>

  <div class="card-right">
    {#if task.assignee_agent}
      <span class="agent-badge" title={task.assignee_agent}>
        {task.assignee_agent.length > 12 ? task.assignee_agent.slice(0, 12) + '…' : task.assignee_agent}
      </span>
    {/if}
    <svg
      class="drag-handle"
      width="10"
      height="14"
      viewBox="0 0 10 14"
      fill="currentColor"
      aria-hidden="true"
    >
      <circle cx="2.5" cy="2.5" r="1.5"/>
      <circle cx="7.5" cy="2.5" r="1.5"/>
      <circle cx="2.5" cy="7" r="1.5"/>
      <circle cx="7.5" cy="7" r="1.5"/>
      <circle cx="2.5" cy="11.5" r="1.5"/>
      <circle cx="7.5" cy="11.5" r="1.5"/>
    </svg>
  </div>
</article>

<style>
  .kanban-card {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    min-height: 56px;
    padding: 8px 10px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-md);
    cursor: grab;
    user-select: none;
    transition: background 0.12s ease, border-color 0.12s ease, box-shadow 0.12s ease;
  }

  .kanban-card:hover {
    background: rgba(255, 255, 255, 0.07);
    border-color: rgba(255, 255, 255, 0.12);
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.25);
  }

  .kanban-card:active {
    cursor: grabbing;
  }

  .card-left {
    display: flex;
    align-items: center;
    gap: 7px;
    min-width: 0;
    flex: 1;
  }

  .priority-dot {
    width: 7px;
    height: 7px;
    border-radius: var(--radius-full);
    flex-shrink: 0;
    box-shadow: 0 0 4px currentColor;
  }

  .task-id {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-muted);
    font-variant-numeric: tabular-nums;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .card-right {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
  }

  .agent-badge {
    font-size: 0.625rem;
    font-weight: 600;
    letter-spacing: 0.03em;
    padding: 2px 6px;
    border-radius: var(--radius-full);
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.1);
    color: var(--text-tertiary);
    white-space: nowrap;
  }

  .drag-handle {
    color: rgba(255, 255, 255, 0.2);
    flex-shrink: 0;
    transition: color 0.12s ease;
  }

  .kanban-card:hover .drag-handle {
    color: rgba(255, 255, 255, 0.4);
  }
</style>
