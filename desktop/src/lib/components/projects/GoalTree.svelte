<script lang="ts">
  import { untrack } from 'svelte';
  import type { GoalTreeNode } from '$lib/stores/projects.svelte';
  import SelfGoalTree from './GoalTree.svelte';

  interface Props {
    nodes: GoalTreeNode[];
    onAddGoal?: (parentId: number) => void;
    level?: number;
  }

  let { nodes, onAddGoal, level = 0 }: Props = $props();

  function collectIds(treeNodes: GoalTreeNode[]): number[] {
    const ids: number[] = [];
    for (const node of treeNodes) {
      ids.push(node.id);
      ids.push(...collectIds(node.children));
    }
    return ids;
  }

  // Track which nodes are expanded (default all expanded).
  // New nodes open by default; existing collapsed nodes stay collapsed.
  let expanded = $state<Set<number>>(new Set());
  let knownNodeIds = $state<Set<number>>(new Set());

  $effect(() => {
    const allIds = collectIds(nodes);
    const currentExpanded = untrack(() => expanded);
    const currentKnownIds = untrack(() => knownNodeIds);

    if (allIds.length === 0) {
      if (currentExpanded.size > 0) {
        expanded = new Set();
      }
      if (currentKnownIds.size > 0) {
        knownNodeIds = new Set();
      }
      return;
    }

    const activeIds = new Set(allIds);
    const nextExpanded = new Set<number>();

    for (const id of currentExpanded) {
      if (activeIds.has(id)) {
        nextExpanded.add(id);
      }
    }

    for (const id of allIds) {
      if (!currentKnownIds.has(id)) {
        nextExpanded.add(id);
      }
    }

    const initialLoad = currentKnownIds.size === 0 && currentExpanded.size === 0;
    const expansionChanged = initialLoad
      || nextExpanded.size !== currentExpanded.size
      || [...nextExpanded].some((id) => !currentExpanded.has(id));
    const knownIdsChanged = currentKnownIds.size !== allIds.length
      || allIds.some((id) => !currentKnownIds.has(id));

    if (expansionChanged) {
      expanded = initialLoad ? new Set(allIds) : nextExpanded;
    }

    if (knownIdsChanged) {
      knownNodeIds = new Set(allIds);
    }
  });

  function toggle(id: number) {
    const next = new Set(expanded);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    expanded = next;
  }

  type GoalStatus = GoalTreeNode['status'];
  type GoalPriorityType = GoalTreeNode['priority'];

  function statusColor(status: GoalStatus): string {
    switch (status) {
      case 'completed':  return 'var(--accent-success)';
      case 'in_progress': return 'var(--accent-warning)';
      case 'blocked':    return 'var(--accent-error)';
      default:           return 'rgba(255,255,255,0.25)';
    }
  }

  function priorityColor(priority: GoalPriorityType): string {
    switch (priority) {
      case 'high':   return 'var(--accent-error)';
      case 'medium': return 'var(--accent-warning)';
      default:       return 'var(--text-muted)';
    }
  }
</script>

<ul
  class="goal-tree"
  class:goal-tree--nested={level > 0}
  role="tree"
  aria-label={level === 0 ? 'Goals' : undefined}
>
  {#each nodes as node (node.id)}
    {@const hasChildren = node.children.length > 0}
    {@const isExpanded = expanded.has(node.id)}
    {@const color = statusColor(node.status)}

    <li
      class="goal-node"
      role="treeitem"
      aria-expanded={hasChildren ? isExpanded : undefined}
      aria-selected={false}
    >
      <div class="goal-row">
        <!-- Expand toggle -->
        <button
          class="goal-toggle"
          class:goal-toggle--invisible={!hasChildren}
          onclick={() => toggle(node.id)}
          aria-label="{isExpanded ? 'Collapse' : 'Expand'} {node.title}"
          tabindex={hasChildren ? 0 : -1}
        >
          <svg
            class="toggle-chevron"
            class:toggle-chevron--open={isExpanded}
            width="10"
            height="10"
            viewBox="0 0 10 10"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
            aria-hidden="true"
          >
            <polyline points="2,3.5 5,6.5 8,3.5"/>
          </svg>
        </button>

        <!-- Status icon -->
        <span class="goal-status-icon" style="color: {color}" aria-hidden="true">
          {#if node.status === 'active'}
            <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
              <circle cx="5" cy="5" r="3.5" stroke="currentColor" stroke-width="1.5"/>
            </svg>
          {:else if node.status === 'in_progress'}
            <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
              <circle cx="5" cy="5" r="4" stroke="currentColor" stroke-width="1.5" stroke-dasharray="4 3" stroke-linecap="round"/>
            </svg>
          {:else if node.status === 'completed'}
            <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
              <circle cx="5" cy="5" r="4"/>
              <polyline points="3,5 4.3,6.3 7.5,3"/>
            </svg>
          {:else}
            <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
              <rect x="1.5" y="1.5" width="7" height="7" rx="1"/>
              <line x1="5" y1="3" x2="5" y2="5.5"/>
              <circle cx="5" cy="7.2" r="0.4" fill="currentColor"/>
            </svg>
          {/if}
        </span>

        <!-- Priority pip -->
        <span
          class="goal-priority"
          style="background: {priorityColor(node.priority)}"
          title="Priority: {node.priority}"
          aria-label="Priority: {node.priority}"
        ></span>

        <!-- Title -->
        <span class="goal-title">{node.title}</span>

        <!-- Task count -->
        {#if (node.task_count ?? 0) > 0}
          <span class="goal-task-count" aria-label="{node.task_count ?? 0} tasks">
            {node.task_count ?? 0}
          </span>
        {/if}

        <!-- Add child goal -->
        {#if onAddGoal}
          <button
            class="goal-add-btn"
            onclick={() => onAddGoal?.(node.id)}
            aria-label="Add child goal to {node.title}"
            title="Add child goal"
          >
            <svg width="9" height="9" viewBox="0 0 9 9" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
              <line x1="4.5" y1="1" x2="4.5" y2="8"/>
              <line x1="1" y1="4.5" x2="8" y2="4.5"/>
            </svg>
          </button>
        {/if}
      </div>

      <!-- Recursive children -->
      {#if hasChildren && isExpanded}
        <div class="goal-children">
          <SelfGoalTree nodes={node.children} {onAddGoal} level={level + 1} />
        </div>
      {/if}
    </li>
  {/each}
</ul>

<style>
  .goal-tree {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .goal-tree--nested {
    padding-left: 18px;
    margin-top: 2px;
    border-left: 1px solid rgba(255, 255, 255, 0.05);
  }

  .goal-node {
    display: flex;
    flex-direction: column;
  }

  .goal-row {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 5px 6px;
    border-radius: var(--radius-sm);
    transition: background 0.12s;
  }

  .goal-row:hover {
    background: rgba(255, 255, 255, 0.04);
  }

  .goal-row:hover .goal-add-btn {
    opacity: 1;
  }

  .goal-toggle {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    border-radius: var(--radius-xs);
    background: none;
    border: none;
    color: var(--text-muted);
    flex-shrink: 0;
    transition: color 0.12s, background 0.12s;
  }

  .goal-toggle:hover {
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-secondary);
  }

  .goal-toggle--invisible {
    pointer-events: none;
    opacity: 0;
  }

  .toggle-chevron {
    transition: transform 0.15s ease;
  }

  .toggle-chevron--open {
    transform: rotate(0deg);
  }

  .toggle-chevron:not(.toggle-chevron--open) {
    transform: rotate(-90deg);
  }

  .goal-status-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    width: 14px;
  }

  .goal-priority {
    width: 4px;
    height: 4px;
    border-radius: 50%;
    flex-shrink: 0;
    opacity: 0.7;
  }

  .goal-title {
    flex: 1;
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.3;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .goal-task-count {
    font-size: 0.625rem;
    font-weight: 600;
    color: var(--text-muted);
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-full);
    padding: 0 5px;
    min-width: 16px;
    text-align: center;
    flex-shrink: 0;
    font-variant-numeric: tabular-nums;
  }

  .goal-add-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    border-radius: var(--radius-xs);
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.07);
    color: rgba(255, 255, 255, 0.3);
    flex-shrink: 0;
    opacity: 0;
    transition: opacity 0.15s, background 0.12s, color 0.12s;
  }

  .goal-add-btn:hover {
    background: rgba(255, 255, 255, 0.07);
    color: rgba(255, 255, 255, 0.6);
    border-color: rgba(255, 255, 255, 0.14);
  }

  .goal-children {
    margin-top: 1px;
  }
</style>
