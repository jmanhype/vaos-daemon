<script lang="ts">
  import type { MemoryEntry, MemoryCategory } from '$lib/stores/memory.svelte';

  // ── Props ────────────────────────────────────────────────────────────────────

  interface Props {
    entry: MemoryEntry;
    onClose?: () => void;
    onUpdate?: (id: string, patch: Partial<Omit<MemoryEntry, 'id' | 'created_at'>>) => void;
    onDelete?: (id: string) => void;
  }

  let { entry, onClose, onUpdate, onDelete }: Props = $props();

  // ── Editable state (reset when entry changes) ─────────────────────────────
  // Initialize empty; $effect below syncs from the reactive `entry` prop.

  let editKey = $state('');
  let editValue = $state('');
  let editCategory = $state<MemoryCategory>('fact');
  let editTags = $state('');

  // Sync form fields whenever the selected entry changes.
  // Accessing `entry` here makes this $effect reactive to prop changes.
  $effect(() => {
    void entry.id; // track the entry identity
    editKey = entry.key;
    editValue = entry.value;
    editCategory = entry.category;
    editTags = entry.tags?.join(', ') ?? '';
  });

  // ── Dirty tracking ────────────────────────────────────────────────────────

  const isDirty = $derived(
    editKey !== entry.key ||
    editValue !== entry.value ||
    editCategory !== entry.category ||
    editTags !== (entry.tags?.join(', ') ?? ''),
  );

  // ── Helpers ──────────────────────────────────────────────────────────────────

  function formatDate(iso: string): string {
    return new Date(iso).toLocaleString(undefined, {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  }

  const CATEGORIES: { value: MemoryCategory; label: string }[] = [
    { value: 'fact',        label: 'Fact' },
    { value: 'preference',  label: 'Preference' },
    { value: 'context',     label: 'Context' },
    { value: 'instruction', label: 'Instruction' },
    { value: 'other',       label: 'Other' },
  ];

  // ── Actions ───────────────────────────────────────────────────────────────

  function handleSave() {
    if (!isDirty) return;
    const tags = editTags
      .split(',')
      .map((t) => t.trim())
      .filter(Boolean);
    onUpdate?.(entry.id, {
      key: editKey.trim(),
      value: editValue.trim(),
      category: editCategory,
      tags,
    });
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') onClose?.();
    if ((e.metaKey || e.ctrlKey) && e.key === 's') {
      e.preventDefault();
      handleSave();
    }
  }
</script>

<!-- ── Detail panel ───────────────────────────────────────────────────────────── -->
<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<section
  class="memory-detail"
  aria-label="Memory detail: {entry.key}"
  onkeydown={handleKeydown}
>
  <!-- ── Panel header ── -->
  <header class="detail-header">
    <h2 class="detail-title truncate" title={entry.key}>{entry.key}</h2>
    <button
      class="close-btn"
      onclick={() => onClose?.()}
      aria-label="Close detail panel"
    >
      <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" aria-hidden="true">
        <line x1="1.5" y1="1.5" x2="10.5" y2="10.5"/>
        <line x1="10.5" y1="1.5" x2="1.5" y2="10.5"/>
      </svg>
    </button>
  </header>

  <!-- ── Form body ── -->
  <div class="detail-body">

    <!-- Key -->
    <div class="field">
      <label class="field-label" for="detail-key">Key</label>
      <input
        id="detail-key"
        class="field-input glass-input"
        type="text"
        bind:value={editKey}
        placeholder="e.g. user.preferred_language"
        aria-label="Memory key"
        spellcheck="false"
      />
    </div>

    <!-- Value -->
    <div class="field">
      <label class="field-label" for="detail-value">Value</label>
      <textarea
        id="detail-value"
        class="field-textarea glass-input"
        bind:value={editValue}
        placeholder="Memory value..."
        rows="5"
        aria-label="Memory value"
        spellcheck="false"
      ></textarea>
    </div>

    <!-- Category -->
    <div class="field">
      <label class="field-label" for="detail-category">Category</label>
      <div class="select-wrapper">
        <select
          id="detail-category"
          class="field-select glass-input"
          bind:value={editCategory}
          aria-label="Memory category"
        >
          {#each CATEGORIES as cat (cat.value)}
            <option value={cat.value}>{cat.label}</option>
          {/each}
        </select>
        <svg class="select-chevron" width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
          <polyline points="2,4 6,8 10,4"/>
        </svg>
      </div>
    </div>

    <!-- Tags -->
    <div class="field">
      <label class="field-label" for="detail-tags">Tags <span class="field-hint">(comma-separated)</span></label>
      <input
        id="detail-tags"
        class="field-input glass-input"
        type="text"
        bind:value={editTags}
        placeholder="e.g. dev, languages, user"
        aria-label="Memory tags, comma separated"
        spellcheck="false"
      />
    </div>

    <!-- Metadata (read-only) -->
    <div class="meta-grid">
      <div class="meta-item">
        <span class="meta-label">Created</span>
        <time class="meta-value" datetime={entry.created_at}>{formatDate(entry.created_at)}</time>
      </div>
      <div class="meta-item">
        <span class="meta-label">Updated</span>
        <time class="meta-value" datetime={entry.updated_at}>{formatDate(entry.updated_at)}</time>
      </div>
    </div>

  </div>

  <!-- ── Actions ── -->
  <footer class="detail-footer">
    <button
      class="btn btn--save"
      onclick={handleSave}
      disabled={!isDirty}
      aria-disabled={!isDirty}
      aria-label="Save changes to memory entry"
    >
      Save Changes
    </button>
    <button
      class="btn btn--delete"
      onclick={() => onDelete?.(entry.id)}
      aria-label="Delete memory entry: {entry.key}"
    >
      Delete
    </button>
  </footer>
</section>

<style>
  /* ── Panel shell ── */

  .memory-detail {
    width: 400px;
    flex-shrink: 0;
    border-left: 1px solid var(--border-default);
    background: rgba(255, 255, 255, 0.02);
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
  }

  /* ── Header ── */

  .detail-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 20px 20px 16px;
    border-bottom: 1px solid var(--border-default);
    flex-shrink: 0;
  }

  .detail-title {
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text-primary);
    font-family: var(--font-mono);
    min-width: 0;
  }

  .close-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    border-radius: var(--radius-sm);
    border: 1px solid var(--border-default);
    background: none;
    color: var(--text-tertiary);
    flex-shrink: 0;
    transition: background 0.12s, border-color 0.12s, color 0.12s;
  }

  .close-btn:hover {
    background: rgba(255, 255, 255, 0.06);
    border-color: var(--border-hover);
    color: var(--text-primary);
  }

  /* ── Body ── */

  .detail-body {
    flex: 1;
    overflow-y: auto;
    padding: 20px;
    display: flex;
    flex-direction: column;
    gap: 16px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  /* ── Fields ── */

  .field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .field-label {
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    color: var(--text-tertiary);
  }

  .field-hint {
    text-transform: none;
    letter-spacing: 0;
    font-weight: 400;
    color: var(--text-muted);
  }

  .field-input {
    padding: 9px 12px;
    font-size: 0.8125rem;
  }

  .field-textarea {
    padding: 9px 12px;
    font-size: 0.8125rem;
    resize: vertical;
    min-height: 80px;
    line-height: 1.5;
  }

  .select-wrapper {
    position: relative;
  }

  .field-select {
    appearance: none;
    -webkit-appearance: none;
    padding: 9px 32px 9px 12px;
    font-size: 0.8125rem;
    cursor: pointer;
    background: rgba(255, 255, 255, 0.06);
  }

  .field-select option {
    background: #1e1e1e;
    color: #fff;
  }

  .select-chevron {
    position: absolute;
    right: 10px;
    top: 50%;
    transform: translateY(-50%);
    pointer-events: none;
    color: var(--text-tertiary);
  }

  /* ── Metadata grid ── */

  .meta-grid {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 14px;
    background: rgba(255, 255, 255, 0.025);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-md);
  }

  .meta-item {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 8px;
    min-width: 0;
  }

  .meta-label {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    color: var(--text-muted);
    flex-shrink: 0;
  }

  .meta-value {
    font-size: 0.75rem;
    color: var(--text-tertiary);
    text-align: right;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* ── Footer actions ── */

  .detail-footer {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 16px 20px;
    border-top: 1px solid var(--border-default);
    flex-shrink: 0;
  }

  .btn {
    flex: 1;
    padding: 9px 14px;
    border-radius: var(--radius-md);
    font-size: 0.8125rem;
    font-weight: 500;
    border: 1px solid transparent;
    transition: background 0.15s, border-color 0.15s, color 0.15s, opacity 0.15s;
  }

  .btn--save {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.15);
    color: var(--text-primary);
  }

  .btn--save:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.15);
    border-color: rgba(255, 255, 255, 0.25);
  }

  .btn--save:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }

  .btn--delete {
    flex: 0 0 auto;
    padding: 9px 14px;
    background: rgba(239, 68, 68, 0.08);
    border-color: rgba(239, 68, 68, 0.18);
    color: rgba(239, 68, 68, 0.75);
  }

  .btn--delete:hover {
    background: rgba(239, 68, 68, 0.14);
    border-color: rgba(239, 68, 68, 0.3);
    color: rgba(239, 68, 68, 0.9);
  }
</style>
