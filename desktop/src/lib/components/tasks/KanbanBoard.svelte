<script lang="ts">
  import KanbanCard from './KanbanCard.svelte';

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
    tasks: KanbanTask[];
    onStatusChange?: (taskId: number, newStatus: string) => void;
    onPriorityChange?: (taskId: number, newPriority: string) => void;
  }

  let { tasks, onStatusChange, onPriorityChange }: Props = $props();

  const columns: { id: string; label: string }[] = [
    { id: 'backlog',     label: 'Backlog' },
    { id: 'todo',        label: 'To Do' },
    { id: 'in_progress', label: 'In Progress' },
    { id: 'in_review',   label: 'In Review' },
    { id: 'done',        label: 'Done' },
  ];

  let dragOverColumn = $state<string | null>(null);

  function columnTasks(status: string): KanbanTask[] {
    return tasks.filter((t) => t.status === status);
  }

  function handleDragOver(e: DragEvent, columnId: string) {
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
    dragOverColumn = columnId;
  }

  function handleDragLeave(e: DragEvent) {
    const related = e.relatedTarget as Node | null;
    const el = (e.currentTarget as HTMLElement);
    if (!el.contains(related)) dragOverColumn = null;
  }

  function handleDrop(e: DragEvent, columnId: string) {
    e.preventDefault();
    dragOverColumn = null;
    const raw = e.dataTransfer?.getData('text/plain');
    if (!raw) return;
    const taskId = Number(raw);
    if (!isNaN(taskId)) onStatusChange?.(taskId, columnId);
  }

  function handleDragEnd() {
    dragOverColumn = null;
  }
</script>

<div class="kanban-board" role="region" aria-label="Kanban board">
  {#each columns as col (col.id)}
    <div
      class="kanban-column"
      class:kanban-column--over={dragOverColumn === col.id}
      ondragover={(e) => handleDragOver(e, col.id)}
      ondragleave={handleDragLeave}
      ondrop={(e) => handleDrop(e, col.id)}
      ondragend={handleDragEnd}
      role="group"
      aria-label="{col.label} column"
    >
      <header class="column-header">
        <span class="column-label">{col.label}</span>
        <span class="column-count" aria-label="{columnTasks(col.id).length} tasks">
          {columnTasks(col.id).length}
        </span>
      </header>

      <div class="column-cards">
        {#each columnTasks(col.id) as task (task.id)}
          <KanbanCard {task} {onPriorityChange} />
        {/each}

        {#if columnTasks(col.id).length === 0}
          <div class="column-empty" aria-label="No tasks">
            <span>Empty</span>
          </div>
        {/if}
      </div>
    </div>
  {/each}
</div>

<style>
  .kanban-board {
    display: flex;
    gap: 12px;
    overflow-x: auto;
    padding-bottom: 8px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
    align-items: flex-start;
  }

  .kanban-column {
    flex: 1 0 200px;
    min-width: 180px;
    max-width: 280px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-lg);
    padding: 10px 8px;
    transition: background 0.15s ease, border-color 0.15s ease;
  }

  .kanban-column--over {
    background: rgba(255, 255, 255, 0.07);
    border-color: rgba(255, 255, 255, 0.15);
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.08);
  }

  .column-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 2px 6px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  }

  .column-label {
    font-size: 0.75rem;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--text-tertiary);
    user-select: none;
  }

  .column-count {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 18px;
    height: 18px;
    padding: 0 5px;
    border-radius: var(--radius-full);
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.09);
    font-size: 0.625rem;
    font-weight: 700;
    color: var(--text-muted);
    font-variant-numeric: tabular-nums;
    user-select: none;
  }

  .column-cards {
    display: flex;
    flex-direction: column;
    gap: 5px;
    min-height: 48px;
  }

  .column-empty {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 48px;
    border-radius: var(--radius-md);
    border: 1px dashed rgba(255, 255, 255, 0.07);
    font-size: 0.6875rem;
    color: var(--text-muted);
    user-select: none;
  }
</style>
