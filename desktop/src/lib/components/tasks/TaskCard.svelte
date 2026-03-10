<script lang="ts">
  // src/lib/components/tasks/TaskCard.svelte
  // Floating pill-shaped task tracker.
  // Inspired by Kit Langton's "stupid sexy composer" UI.

  import { slide, fade } from 'svelte/transition';
  import { cubicOut } from 'svelte/easing';
  import TaskCheckbox from './TaskCheckbox.svelte';
  import type { Task } from '$lib/stores/tasks.svelte';

  interface Props {
    tasks: Task[];
    onAsk?: (question: string) => void;
  }

  let { tasks, onAsk }: Props = $props();

  // ── Local State ──────────────────────────────────────────────────────────────

  let isExpanded = $state(true);
  let inputValue = $state('');

  // ── Derived ──────────────────────────────────────────────────────────────────

  const completedCount = $derived(tasks.filter((t) => t.status === 'completed').length);
  const totalCount = $derived(tasks.length);
  const allDone = $derived(completedCount === totalCount && totalCount > 0);
  const progressPct = $derived(totalCount > 0 ? (completedCount / totalCount) * 100 : 0);

  // ── Actions ──────────────────────────────────────────────────────────────────

  function toggleExpanded() {
    isExpanded = !isExpanded;
  }

  function handleAsk() {
    const val = inputValue.trim();
    if (!val) return;
    onAsk?.(val);
    inputValue = '';
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter') {
      e.preventDefault();
      handleAsk();
    }
  }

  // ── Status helpers ───────────────────────────────────────────────────────────

  function statusLabel(task: Task): string {
    switch (task.status) {
      case 'completed': return 'completed';
      case 'active':    return 'in progress';
      case 'failed':    return 'failed';
      default:          return 'pending';
    }
  }
</script>

<div class="task-card" role="region" aria-label="Task progress">
  <!-- ── Header ── -->
  <header class="task-card__header">
    <div class="task-card__progress-group">
      <!-- Mini progress ring -->
      <div class="progress-ring" aria-hidden="true">
        <svg viewBox="0 0 28 28" fill="none" xmlns="http://www.w3.org/2000/svg">
          <circle
            cx="14" cy="14" r="11"
            stroke="rgba(255,255,255,0.08)"
            stroke-width="2.5"
          />
          <circle
            cx="14" cy="14" r="11"
            stroke={allDone ? 'var(--accent-success)' : 'var(--accent-primary)'}
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-dasharray={69.1}
            stroke-dashoffset={69.1 - (69.1 * progressPct) / 100}
            style="transform: rotate(-90deg); transform-origin: center; transition: stroke-dashoffset 0.4s cubic-bezier(0.4, 0, 0.2, 1), stroke 0.3s ease;"
          />
        </svg>
      </div>

      <span class="task-card__count" aria-live="polite" aria-atomic="true">
        {#if allDone}
          <span class="task-card__count-all-done">All done</span>
        {:else}
          <span class="task-card__count-num">{completedCount}</span>
          <span class="task-card__count-sep"> of </span>
          <span class="task-card__count-num">{totalCount}</span>
          <span class="task-card__count-label"> completed</span>
        {/if}
      </span>
    </div>

    <button
      class="task-card__toggle"
      onclick={toggleExpanded}
      aria-expanded={isExpanded}
      aria-label={isExpanded ? 'Collapse task list' : 'Expand task list'}
    >
      <svg
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2.5"
        stroke-linecap="round"
        stroke-linejoin="round"
        class="toggle-chevron"
        class:toggle-chevron--up={isExpanded}
        aria-hidden="true"
      >
        <polyline points="6 9 12 15 18 9" />
      </svg>
    </button>
  </header>

  <!-- ── Task list (collapsible) ── -->
  {#if isExpanded}
    <div
      class="task-card__body"
      transition:slide={{ duration: 220, easing: cubicOut }}
    >
      <!-- Thin progress bar -->
      <div class="progress-bar" aria-hidden="true">
        <div
          class="progress-bar__fill"
          class:progress-bar__fill--done={allDone}
          style="width: {progressPct}%"
        ></div>
      </div>

      <!-- Task rows -->
      <ul class="task-list" role="list" aria-label="Task list">
        {#each tasks as task (task.id)}
          <li
            class="task-row"
            class:task-row--active={task.status === 'active'}
            class:task-row--completed={task.status === 'completed'}
            class:task-row--failed={task.status === 'failed'}
            in:fade={{ duration: 180, easing: cubicOut }}
            aria-label="{task.text}, {statusLabel(task)}"
          >
            <TaskCheckbox status={task.status} size={17} />

            <span class="task-row__text">
              {task.text}
            </span>

            {#if task.status === 'active'}
              <span class="task-row__badge task-row__badge--active" aria-hidden="true">
                running
              </span>
            {:else if task.status === 'failed'}
              <span class="task-row__badge task-row__badge--failed" aria-hidden="true">
                failed
              </span>
            {/if}
          </li>
        {/each}

        {#if tasks.length === 0}
          <li class="task-row task-row--empty" aria-label="No tasks yet">
            <span class="task-row__text task-row__text--muted">No tasks yet…</span>
          </li>
        {/if}
      </ul>

      <!-- Divider -->
      <div class="task-card__divider" aria-hidden="true"></div>

      <!-- Ask input -->
      <div class="task-card__input-row">
        <input
          bind:value={inputValue}
          type="text"
          class="task-card__input"
          placeholder="Ask anything…"
          onkeydown={handleKeydown}
          aria-label="Ask a question about tasks"
        />
        <button
          class="task-card__send"
          onclick={handleAsk}
          disabled={!inputValue.trim()}
          aria-label="Send question"
        >
          <svg
            width="13"
            height="13"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <line x1="22" y1="2" x2="11" y2="13" />
            <polygon points="22 2 15 22 11 13 2 9 22 2" />
          </svg>
        </button>
      </div>
    </div>
  {/if}
</div>

<style>
  /* ── Card shell ── */
  .task-card {
    width: 100%;
    max-width: 400px;
    background: rgba(22, 22, 24, 0.92);
    backdrop-filter: blur(40px) saturate(1.6);
    -webkit-backdrop-filter: blur(40px) saturate(1.6);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 16px;
    box-shadow:
      0 8px 32px rgba(0, 0, 0, 0.45),
      inset 0 1px 0 rgba(255, 255, 255, 0.06);
    overflow: hidden;
  }

  /* ── Header ── */
  .task-card__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 14px;
    min-height: 44px;
  }

  .task-card__progress-group {
    display: flex;
    align-items: center;
    gap: 9px;
  }

  /* Mini progress ring */
  .progress-ring {
    width: 28px;
    height: 28px;
    flex-shrink: 0;
  }

  .progress-ring svg {
    display: block;
  }

  /* Count label */
  .task-card__count {
    font-size: 0.8125rem;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.75);
    letter-spacing: -0.01em;
    user-select: none;
  }

  .task-card__count-num {
    color: #fff;
    font-weight: 600;
  }

  .task-card__count-sep,
  .task-card__count-label {
    color: rgba(255, 255, 255, 0.45);
  }

  .task-card__count-all-done {
    color: var(--accent-success);
    font-weight: 600;
  }

  /* Collapse toggle */
  .task-card__toggle {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: none;
    border: none;
    border-radius: 6px;
    color: rgba(255, 255, 255, 0.3);
    cursor: pointer;
    transition: color 0.15s, background 0.15s;
    flex-shrink: 0;
  }

  .task-card__toggle:hover {
    color: rgba(255, 255, 255, 0.65);
    background: rgba(255, 255, 255, 0.07);
  }

  .toggle-chevron {
    transition: transform 0.22s cubic-bezier(0.4, 0, 0.2, 1);
  }

  .toggle-chevron--up {
    transform: rotate(180deg);
  }

  /* ── Body ── */
  .task-card__body {
    display: flex;
    flex-direction: column;
  }

  /* Thin progress bar */
  .progress-bar {
    height: 2px;
    background: rgba(255, 255, 255, 0.05);
    margin: 0 14px 10px;
    border-radius: 9999px;
    overflow: hidden;
  }

  .progress-bar__fill {
    height: 100%;
    background: var(--accent-primary);
    border-radius: 9999px;
    transition: width 0.4s cubic-bezier(0.4, 0, 0.2, 1);
  }

  .progress-bar__fill--done {
    background: var(--accent-success);
  }

  /* ── Task list ── */
  .task-list {
    list-style: none;
    display: flex;
    flex-direction: column;
    gap: 1px;
    padding: 0 8px;
    max-height: 220px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  /* ── Task row ── */
  .task-row {
    display: flex;
    align-items: center;
    gap: 9px;
    padding: 6px 6px;
    border-radius: 8px;
    transition: background 0.12s;
  }

  .task-row:hover {
    background: rgba(255, 255, 255, 0.03);
  }

  /* Active row highlight */
  .task-row--active {
    background: rgba(59, 130, 246, 0.07);
  }

  .task-row--active:hover {
    background: rgba(59, 130, 246, 0.1);
  }

  .task-row__text {
    flex: 1;
    font-size: 0.8125rem;
    line-height: 1.45;
    color: rgba(255, 255, 255, 0.85);
    letter-spacing: -0.01em;
    word-break: break-word;
    min-width: 0;
  }

  /* Active: bold white */
  .task-row--active .task-row__text {
    color: #fff;
    font-weight: 500;
  }

  /* Completed: strikethrough + dimmed */
  .task-row--completed .task-row__text {
    text-decoration: line-through;
    text-decoration-color: rgba(255, 255, 255, 0.2);
    color: rgba(255, 255, 255, 0.35);
  }

  /* Failed: red tint */
  .task-row--failed .task-row__text {
    color: rgba(239, 68, 68, 0.7);
    text-decoration: line-through;
    text-decoration-color: rgba(239, 68, 68, 0.3);
  }

  /* Muted empty state text */
  .task-row__text--muted {
    color: rgba(255, 255, 255, 0.2);
    font-style: italic;
  }

  .task-row--empty {
    justify-content: center;
    padding: 10px 6px;
  }

  /* Status badge */
  .task-row__badge {
    font-size: 0.625rem;
    font-weight: 600;
    letter-spacing: 0.07em;
    text-transform: uppercase;
    padding: 2px 7px;
    border-radius: 9999px;
    flex-shrink: 0;
  }

  .task-row__badge--active {
    background: rgba(59, 130, 246, 0.15);
    color: #93c5fd;
    animation: badge-pulse 2s ease-in-out infinite;
  }

  @keyframes badge-pulse {
    0%, 100% { opacity: 1; }
    50%       { opacity: 0.55; }
  }

  .task-row__badge--failed {
    background: rgba(239, 68, 68, 0.12);
    color: #fca5a5;
  }

  /* ── Divider ── */
  .task-card__divider {
    height: 1px;
    margin: 10px 0 0;
    background: linear-gradient(
      90deg,
      transparent,
      rgba(255, 255, 255, 0.07) 30%,
      rgba(255, 255, 255, 0.07) 70%,
      transparent
    );
  }

  /* ── Input row ── */
  .task-card__input-row {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 10px;
  }

  .task-card__input {
    flex: 1;
    background: transparent;
    border: none;
    outline: none;
    color: rgba(255, 255, 255, 0.82);
    font-size: 0.8125rem;
    font-family: inherit;
    line-height: 1.5;
    min-width: 0;
  }

  .task-card__input::placeholder {
    color: rgba(255, 255, 255, 0.22);
  }

  /* Send button */
  .task-card__send {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(255, 255, 255, 0.9);
    border: none;
    border-radius: 7px;
    color: #000;
    cursor: pointer;
    flex-shrink: 0;
    transition: background 0.12s, transform 0.1s, opacity 0.12s;
  }

  .task-card__send:hover:not(:disabled) {
    background: #fff;
    transform: scale(1.06);
  }

  .task-card__send:disabled {
    background: rgba(255, 255, 255, 0.1);
    color: rgba(255, 255, 255, 0.18);
    cursor: not-allowed;
  }
</style>
