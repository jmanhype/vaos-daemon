<script lang="ts">
  import type { MemoryEntry, MemoryCategory } from '$lib/stores/memory.svelte';

  // ── Props ────────────────────────────────────────────────────────────────────

  interface Props {
    entry: MemoryEntry;
    selected?: boolean;
    onSelect?: (entry: MemoryEntry) => void;
    onDelete?: (id: string) => void;
  }

  let { entry, selected = false, onSelect, onDelete }: Props = $props();

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function formatRelative(iso: string): string {
    const diff = Date.now() - new Date(iso).getTime();
    const s = Math.floor(diff / 1000);
    if (s < 60) return 'just now';
    const m = Math.floor(s / 60);
    if (m < 60) return `${m}m ago`;
    const h = Math.floor(m / 60);
    if (h < 24) return `${h}h ago`;
    const d = Math.floor(h / 24);
    if (d < 30) return `${d}d ago`;
    return new Date(iso).toLocaleDateString();
  }

  function categoryLabel(cat: MemoryCategory): string {
    switch (cat) {
      case 'fact':        return 'Fact';
      case 'preference':  return 'Preference';
      case 'context':     return 'Context';
      case 'instruction': return 'Instruction';
      case 'other':       return 'Other';
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onSelect?.(entry);
    }
  }

  function handleDeleteClick(e: MouseEvent) {
    e.stopPropagation();
    onDelete?.(entry.id);
  }
</script>

<!-- ── Card ──────────────────────────────────────────────────────────────────── -->
<div
  class="memory-card"
  class:memory-card--selected={selected}
  onclick={() => onSelect?.(entry)}
  onkeydown={handleKeydown}
  role="button"
  tabindex="0"
  aria-pressed={selected}
  aria-label="Memory entry: {entry.key}"
>
  <!-- Relevance indicator bar is omitted — MemoryEntry has no relevance field -->

  <!-- ── Header ── -->
  <header class="card-header">
    <h3 class="card-key truncate" title={entry.key}>{entry.key}</h3>

    <div class="card-header-right">
      <span class="category-badge category-badge--{entry.category}" aria-label="Category: {categoryLabel(entry.category)}">
        {categoryLabel(entry.category)}
      </span>

      <button
        class="delete-btn"
        onclick={handleDeleteClick}
        aria-label="Delete memory entry: {entry.key}"
        tabindex="-1"
      >
        <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" aria-hidden="true">
          <line x1="1.5" y1="1.5" x2="8.5" y2="8.5"/>
          <line x1="8.5" y1="1.5" x2="1.5" y2="8.5"/>
        </svg>
      </button>
    </div>
  </header>

  <!-- ── Value preview ── -->
  <p class="card-value">{entry.value}</p>

  <!-- ── Footer ── -->
  <footer class="card-footer">
    <span class="card-source truncate">{entry.tags.length > 0 ? entry.tags[0] : 'memory'}</span>
    <time class="card-time" datetime={entry.updated_at}>
      {formatRelative(entry.updated_at)}
    </time>
  </footer>

  <!-- ── Tags (if any) ── -->
  {#if entry.tags && entry.tags.length > 0}
    <div class="card-tags" aria-label="Tags">
      {#each entry.tags.slice(0, 4) as tag (tag)}
        <span class="card-tag">{tag}</span>
      {/each}
      {#if entry.tags.length > 4}
        <span class="card-tag card-tag--more">+{entry.tags.length - 4}</span>
      {/if}
    </div>
  {/if}
</div>

<style>
  /* ── Card shell ── */

  .memory-card {
    position: relative;
    background: var(--bg-surface);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
    padding: 16px;
    cursor: pointer;
    display: flex;
    flex-direction: column;
    gap: 8px;
    transition:
      border-color 0.15s ease,
      box-shadow 0.15s ease,
      background 0.15s ease;
    outline: none;
    text-align: left;
    width: 100%;
    overflow: hidden;
  }

  .memory-card:hover {
    background: var(--bg-elevated);
    border-color: var(--border-hover);
  }

  .memory-card:focus-visible {
    border-color: var(--border-focus);
    box-shadow: 0 0 0 2px rgba(255, 255, 255, 0.08);
  }

  .memory-card--selected {
    border-color: rgba(255, 255, 255, 0.22);
    background: rgba(255, 255, 255, 0.05);
    box-shadow:
      0 0 0 1px rgba(255, 255, 255, 0.08),
      inset 0 1px 0 rgba(255, 255, 255, 0.06);
  }

  /* Show delete button only on hover */
  .delete-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: var(--radius-xs);
    border: 1px solid transparent;
    background: none;
    color: var(--text-tertiary);
    opacity: 0;
    transition: opacity 0.12s ease, background 0.12s ease, color 0.12s ease;
    flex-shrink: 0;
  }

  .memory-card:hover .delete-btn {
    opacity: 1;
  }

  .delete-btn:hover {
    background: rgba(239, 68, 68, 0.1);
    border-color: rgba(239, 68, 68, 0.2);
    color: rgba(239, 68, 68, 0.8);
  }

  /* ── Header ── */

  .card-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 8px;
    min-width: 0;
  }

  .card-header-right {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
  }

  .card-key {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary);
    line-height: 1.3;
    font-family: var(--font-mono);
    min-width: 0;
  }

  /* ── Category badge ── */

  .category-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    border-radius: var(--radius-full);
    font-size: 0.625rem;
    font-weight: 600;
    letter-spacing: 0.05em;
    text-transform: uppercase;
    white-space: nowrap;
    flex-shrink: 0;
  }

  .category-badge--fact {
    background: rgba(59, 130, 246, 0.12);
    color: rgba(96, 165, 250, 0.9);
    border: 1px solid rgba(59, 130, 246, 0.2);
  }

  .category-badge--preference {
    background: rgba(168, 85, 247, 0.12);
    color: rgba(192, 132, 252, 0.9);
    border: 1px solid rgba(168, 85, 247, 0.2);
  }

  .category-badge--context {
    background: rgba(34, 197, 94, 0.1);
    color: rgba(74, 222, 128, 0.9);
    border: 1px solid rgba(34, 197, 94, 0.18);
  }

  .category-badge--instruction {
    background: rgba(245, 158, 11, 0.1);
    color: rgba(251, 191, 36, 0.9);
    border: 1px solid rgba(245, 158, 11, 0.2);
  }

  .category-badge--other {
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-tertiary);
    border: 1px solid var(--border-default);
  }

  /* ── Value preview ── */

  .card-value {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.5;
    /* Two-line clamp */
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    overflow: hidden;
  }

  /* ── Footer ── */

  .card-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }

  .card-source {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    max-width: 60%;
  }

  .card-time {
    font-size: 0.6875rem;
    color: var(--text-muted);
    flex-shrink: 0;
    font-variant-numeric: tabular-nums;
  }

  /* ── Tags ── */

  .card-tags {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
  }

  .card-tag {
    font-size: 0.625rem;
    padding: 1px 6px;
    border-radius: var(--radius-xs);
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.07);
    color: var(--text-tertiary);
    font-weight: 500;
  }

  .card-tag--more {
    color: var(--text-muted);
  }
</style>
