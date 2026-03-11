<script lang="ts">
  import { onMount } from 'svelte';
  import { memoryStore, type MemoryCategory, type SortMode } from '$lib/stores/memory.svelte';
  import MemoryCard from '$lib/components/memory/MemoryCard.svelte';
  import MemoryDetail from '$lib/components/memory/MemoryDetail.svelte';

  // ── Add memory form state ─────────────────────────────────────────────────────

  let showAddForm = $state(false);
  let addKey = $state('');
  let addValue = $state('');
  let addCategory = $state<MemoryCategory>('fact');
  let addTags = $state('');
  let addSubmitting = $state(false);

  // ── Category tabs ─────────────────────────────────────────────────────────────

  type TabId = 'all' | MemoryCategory;

  const TABS: { id: TabId; label: string }[] = [
    { id: 'all',         label: 'All' },
    { id: 'fact',        label: 'Facts' },
    { id: 'preference',  label: 'Preferences' },
    { id: 'context',     label: 'Context' },
    { id: 'instruction', label: 'Instructions' },
    { id: 'other',       label: 'Other' },
  ];

  function tabCount(id: TabId): number {
    if (id === 'all') return memoryStore.totalCount;
    return memoryStore.categoryCounts[id] ?? 0;
  }

  // ── Sort options ──────────────────────────────────────────────────────────────

  const SORT_OPTIONS: { value: SortMode; label: string }[] = [
    { value: 'relevance', label: 'By Relevance' },
    { value: 'updated',   label: 'Recently Updated' },
    { value: 'key',       label: 'By Key (A–Z)' },
  ];

  // ── Actions ───────────────────────────────────────────────────────────────────

  async function handleAdd() {
    const keyTrimmed = addKey.trim();
    const valueTrimmed = addValue.trim();
    if (!keyTrimmed || !valueTrimmed) return;

    addSubmitting = true;
    const tags = addTags.split(',').map((t) => t.trim()).filter(Boolean);

    await memoryStore.addMemory({
      key: keyTrimmed,
      value: valueTrimmed,
      category: addCategory,
      tags,
    });

    // Reset form
    addKey = '';
    addValue = '';
    addCategory = 'fact';
    addTags = '';
    showAddForm = false;
    addSubmitting = false;
  }

  function handleCancelAdd() {
    addKey = '';
    addValue = '';
    addCategory = 'fact';
    addTags = '';
    showAddForm = false;
  }

  async function handleUpdate(
    id: string,
    patch: Partial<Omit<import('$lib/stores/memory.svelte').MemoryEntry, 'id' | 'created_at'>>,
  ) {
    await memoryStore.updateMemory(id, patch);
  }

  async function handleDelete(id: string) {
    await memoryStore.deleteMemory(id);
  }

  function handleCardDelete(id: string) {
    void memoryStore.deleteMemory(id);
  }

  // ── Keyboard shorthand: Escape closes add form or clears search ───────────────

  function handlePageKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      if (showAddForm) {
        handleCancelAdd();
      } else if (memoryStore.searchQuery) {
        memoryStore.setSearch('');
      } else {
        memoryStore.select(null);
      }
    }
  }

  // ── Initial fetch ─────────────────────────────────────────────────────────────

  onMount(() => {
    memoryStore.fetchMemories();
  });
</script>

<svelte:window onkeydown={handlePageKeydown} />

<!-- ── Page shell ─────────────────────────────────────────────────────────────── -->
<div class="memory-page">

  <!-- ── Header ── -->
  <header class="page-header">
    <div class="header-left">
      <h1 class="page-title">Memory Vault</h1>
      <p class="page-subtitle">Persistent knowledge and context</p>
    </div>

    <div class="header-right">
      <!-- Sort dropdown -->
      <div class="sort-wrapper">
        <select
          class="sort-select"
          value={memoryStore.sortBy}
          onchange={(e) => memoryStore.setSort((e.currentTarget as HTMLSelectElement).value as SortMode)}
          aria-label="Sort memory entries"
        >
          {#each SORT_OPTIONS as opt (opt.value)}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
        <svg class="sort-chevron" width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
          <polyline points="2,3.5 5.5,7 9,3.5"/>
        </svg>
      </div>

      <!-- Add Memory button -->
      <button
        class="add-btn"
        class:add-btn--active={showAddForm}
        onclick={() => { showAddForm = !showAddForm; }}
        aria-expanded={showAddForm}
        aria-controls="add-memory-form"
        aria-label="Add new memory entry"
      >
        <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" aria-hidden="true">
          <line x1="6.5" y1="1" x2="6.5" y2="12"/>
          <line x1="1" y1="6.5" x2="12" y2="6.5"/>
        </svg>
        Add Memory
      </button>
    </div>
  </header>

  <!-- ── Add memory form (inline) ── -->
  {#if showAddForm}
    <div class="add-form-wrap" id="add-memory-form" role="form" aria-label="Add new memory entry">
      <div class="add-form">
        <div class="add-form-row">
          <div class="add-field add-field--key">
            <label class="add-label" for="add-key">Key</label>
            <input
              id="add-key"
              class="glass-input add-input"
              type="text"
              bind:value={addKey}
              placeholder="e.g. user.preferred_language"
              spellcheck="false"
              aria-label="Memory key"
            />
          </div>
          <div class="add-field add-field--category">
            <label class="add-label" for="add-category">Category</label>
            <div class="select-wrapper">
              <select
                id="add-category"
                class="glass-input add-select"
                bind:value={addCategory}
                aria-label="Memory category"
              >
                <option value="fact">Fact</option>
                <option value="preference">Preference</option>
                <option value="context">Context</option>
                <option value="instruction">Instruction</option>
                <option value="other">Other</option>
              </select>
              <svg class="select-chevron-inner" width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
                <polyline points="2,3.5 5.5,7 9,3.5"/>
              </svg>
            </div>
          </div>
        </div>

        <div class="add-field">
          <label class="add-label" for="add-value">Value</label>
          <textarea
            id="add-value"
            class="glass-input add-textarea"
            bind:value={addValue}
            placeholder="Memory value..."
            rows="3"
            spellcheck="false"
            aria-label="Memory value"
          ></textarea>
        </div>

        <div class="add-field">
          <label class="add-label" for="add-tags">Tags <span class="add-label-hint">(comma-separated, optional)</span></label>
          <input
            id="add-tags"
            class="glass-input add-input"
            type="text"
            bind:value={addTags}
            placeholder="e.g. dev, languages"
            spellcheck="false"
            aria-label="Memory tags, comma separated, optional"
          />
        </div>

        <div class="add-form-actions">
          <button
            class="form-btn form-btn--submit"
            onclick={handleAdd}
            disabled={addSubmitting || !addKey.trim() || !addValue.trim()}
            aria-label="Save new memory entry"
          >
            {addSubmitting ? 'Saving...' : 'Save Memory'}
          </button>
          <button
            class="form-btn form-btn--cancel"
            onclick={handleCancelAdd}
            aria-label="Cancel adding memory"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
  {/if}

  <!-- ── Search bar ── -->
  <div class="search-row">
    <div class="search-wrap">
      <svg class="search-icon" width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
        <circle cx="6" cy="6" r="4.5"/>
        <line x1="9.5" y1="9.5" x2="13" y2="13"/>
      </svg>
      <input
        class="glass-input search-input"
        type="search"
        placeholder="Search keys, values, or tags..."
        value={memoryStore.searchQuery}
        oninput={(e) => memoryStore.setSearch((e.currentTarget as HTMLInputElement).value)}
        aria-label="Search memory entries"
        spellcheck="false"
      />
      {#if memoryStore.searchQuery}
        <button
          class="search-clear"
          onclick={() => memoryStore.setSearch('')}
          aria-label="Clear search"
        >
          <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" aria-hidden="true">
            <line x1="1.5" y1="1.5" x2="8.5" y2="8.5"/>
            <line x1="8.5" y1="1.5" x2="1.5" y2="8.5"/>
          </svg>
        </button>
      {/if}
    </div>
  </div>

  <!-- ── Category tabs ── -->
  <div class="tab-row" role="tablist" aria-label="Filter by category">
    {#each TABS as tab (tab.id)}
      <button
        class="tab"
        class:tab--active={memoryStore.filterCategory === tab.id}
        role="tab"
        aria-selected={memoryStore.filterCategory === tab.id}
        onclick={() => memoryStore.setFilter(tab.id)}
        aria-label="Show {tab.label} ({tabCount(tab.id)})"
      >
        {tab.label}
        <span class="tab-count">{tabCount(tab.id)}</span>
      </button>
    {/each}
  </div>

  <!-- ── Master-detail body ── -->
  <div class="body-row">

    <!-- ── Left panel: card grid ── -->
    <div
      class="card-panel"
      class:card-panel--narrow={memoryStore.selected !== null}
      role="tabpanel"
      aria-label="Memory entries"
    >
      {#if memoryStore.loading}
        <div class="status-state" role="status" aria-live="polite">
          <span class="loading-spinner" aria-hidden="true"></span>
          <span class="status-label">Loading memories...</span>
        </div>

      {:else if memoryStore.filtered.length === 0}
        <!-- Empty state: distinguish truly empty vs filtered empty -->
        {#if memoryStore.totalCount === 0}
          <div class="empty-state" role="status">
            <div class="empty-icon" aria-hidden="true">
              <svg width="44" height="44" viewBox="0 0 44 44" fill="none" xmlns="http://www.w3.org/2000/svg">
                <rect x="6" y="6" width="32" height="32" rx="6" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.2"/>
                <path d="M14 22h16M22 14v16" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.35"/>
              </svg>
            </div>
            <p class="empty-title">No memories yet</p>
            <p class="empty-subtitle">Add facts, preferences, context, and instructions for the agent to remember across sessions.</p>
            <button
              class="empty-cta"
              onclick={() => { showAddForm = true; }}
              aria-label="Add first memory entry"
            >
              Add your first memory
            </button>
          </div>
        {:else}
          <div class="empty-state" role="status">
            <div class="empty-icon" aria-hidden="true">
              <svg width="40" height="40" viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
                <circle cx="18" cy="18" r="11" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.3"/>
                <line x1="26.5" y1="26.5" x2="36" y2="36" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.3"/>
              </svg>
            </div>
            <p class="empty-title">No results</p>
            <p class="empty-subtitle">No memories match your current search or filter.</p>
            <button
              class="empty-cta"
              onclick={() => { memoryStore.setSearch(''); memoryStore.setFilter('all'); }}
              aria-label="Clear filters to show all memories"
            >
              Clear filters
            </button>
          </div>
        {/if}

      {:else}
        <div class="memory-grid" role="list" aria-label="Memory entries">
          {#each memoryStore.filtered as entry (entry.id)}
            <div role="listitem">
              <MemoryCard
                {entry}
                selected={memoryStore.selectedId === entry.id}
                onSelect={() => memoryStore.select(entry.id)}
                onDelete={handleCardDelete}
              />
            </div>
          {/each}
        </div>
      {/if}
    </div>

    <!-- ── Right panel: detail view ── -->
    {#if memoryStore.selected !== null}
      <MemoryDetail
        entry={memoryStore.selected}
        onClose={() => memoryStore.select(null)}
        onUpdate={handleUpdate}
        onDelete={handleDelete}
      />
    {/if}
  </div>

  <!-- ── Error banner ── -->
  {#if memoryStore.error}
    <div class="error-banner" role="alert">
      <span class="error-dot" aria-hidden="true"></span>
      <span class="error-text">{memoryStore.error}</span>
      <button
        class="error-dismiss"
        onclick={() => memoryStore.clearError()}
        aria-label="Dismiss error"
      >
        Dismiss
      </button>
    </div>
  {/if}
</div>

<style>
  /* ── Page layout ── */

  .memory-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  /* ── Header ── */

  .page-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 24px 0;
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
    line-height: 1.2;
  }

  .page-subtitle {
    font-size: 0.75rem;
    color: var(--text-tertiary);
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  /* ── Sort dropdown ── */

  .sort-wrapper {
    position: relative;
    display: flex;
    align-items: center;
  }

  .sort-select {
    appearance: none;
    -webkit-appearance: none;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-md);
    padding: 6px 28px 6px 10px;
    font-size: 0.75rem;
    color: var(--text-secondary);
    cursor: pointer;
    transition: border-color 0.15s;
    outline: none;
  }

  .sort-select:hover {
    border-color: rgba(255, 255, 255, 0.15);
    color: var(--text-primary);
  }

  .sort-select option {
    background: #1e1e1e;
    color: #fff;
  }

  .sort-chevron {
    position: absolute;
    right: 8px;
    pointer-events: none;
    color: var(--text-tertiary);
  }

  /* ── Add button ── */

  .add-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 7px 14px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-md);
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-primary);
    transition: background 0.15s, border-color 0.15s;
  }

  .add-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
  }

  .add-btn--active {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.2);
  }

  /* ── Add form ── */

  .add-form-wrap {
    padding: 0 24px;
    flex-shrink: 0;
  }

  .add-form {
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-md);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    margin-top: 16px;
  }

  .add-form-row {
    display: grid;
    grid-template-columns: 1fr 160px;
    gap: 10px;
  }

  .add-field {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }

  .add-label {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    color: var(--text-tertiary);
  }

  .add-label-hint {
    text-transform: none;
    letter-spacing: 0;
    font-weight: 400;
    color: var(--text-muted);
  }

  .add-input {
    font-size: 0.8125rem;
    padding: 8px 11px;
  }

  .add-textarea {
    font-size: 0.8125rem;
    padding: 8px 11px;
    resize: vertical;
    min-height: 64px;
    line-height: 1.5;
  }

  .add-select {
    appearance: none;
    -webkit-appearance: none;
    font-size: 0.8125rem;
    padding: 8px 28px 8px 11px;
    cursor: pointer;
  }

  .add-select option {
    background: #1e1e1e;
    color: #fff;
  }

  .select-wrapper {
    position: relative;
  }

  .select-chevron-inner {
    position: absolute;
    right: 9px;
    top: 50%;
    transform: translateY(-50%);
    pointer-events: none;
    color: var(--text-tertiary);
  }

  .add-form-actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .form-btn {
    padding: 8px 16px;
    border-radius: var(--radius-md);
    font-size: 0.8125rem;
    font-weight: 500;
    border: 1px solid transparent;
    transition: background 0.15s, border-color 0.15s, opacity 0.15s;
  }

  .form-btn--submit {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.16);
    color: var(--text-primary);
  }

  .form-btn--submit:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.15);
    border-color: rgba(255, 255, 255, 0.25);
  }

  .form-btn--submit:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }

  .form-btn--cancel {
    background: none;
    border-color: transparent;
    color: var(--text-tertiary);
  }

  .form-btn--cancel:hover {
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.04);
  }

  /* ── Search bar ── */

  .search-row {
    padding: 16px 24px 0;
    flex-shrink: 0;
  }

  .search-wrap {
    position: relative;
    display: flex;
    align-items: center;
  }

  .search-icon {
    position: absolute;
    left: 12px;
    color: var(--text-tertiary);
    pointer-events: none;
  }

  .search-input {
    padding-left: 36px !important;
    font-size: 0.875rem;
  }

  .search-clear {
    position: absolute;
    right: 10px;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    border-radius: var(--radius-xs);
    border: none;
    background: none;
    color: var(--text-tertiary);
    transition: color 0.12s;
  }

  .search-clear:hover {
    color: var(--text-secondary);
  }

  /* ── Category tabs ── */

  .tab-row {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 12px 24px 0;
    flex-shrink: 0;
    overflow-x: auto;
    scrollbar-width: none;
  }

  .tab-row::-webkit-scrollbar {
    display: none;
  }

  .tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 5px 12px;
    border-radius: var(--radius-full);
    border: 1px solid transparent;
    background: none;
    color: var(--text-tertiary);
    font-size: 0.75rem;
    font-weight: 500;
    white-space: nowrap;
    transition: background 0.12s, border-color 0.12s, color 0.12s;
  }

  .tab:hover:not(.tab--active) {
    background: rgba(255, 255, 255, 0.04);
    color: var(--text-secondary);
  }

  .tab--active {
    background: rgba(255, 255, 255, 0.08);
    border-color: rgba(255, 255, 255, 0.12);
    color: var(--text-primary);
  }

  .tab-count {
    font-size: 0.625rem;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    background: rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-full);
    padding: 1px 6px;
    color: var(--text-muted);
    min-width: 18px;
    text-align: center;
  }

  .tab--active .tab-count {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text-tertiary);
  }

  /* ── Body: master-detail row ── */

  .body-row {
    flex: 1;
    display: flex;
    overflow: hidden;
    margin-top: 12px;
  }

  /* ── Card panel ── */

  .card-panel {
    flex: 1;
    overflow-y: auto;
    padding: 0 24px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
    min-width: 0;
  }

  /* ── Memory grid ── */

  .memory-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 10px;
  }

  .card-panel--narrow .memory-grid {
    grid-template-columns: 1fr;
  }

  /* ── Status / loading ── */

  .status-state {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 10px;
    min-height: 200px;
    color: var(--text-tertiary);
  }

  .loading-spinner {
    width: 16px;
    height: 16px;
    border: 1.5px solid rgba(255, 255, 255, 0.1);
    border-top-color: rgba(255, 255, 255, 0.5);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
    flex-shrink: 0;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .status-label {
    font-size: 0.8125rem;
  }

  /* ── Empty states ── */

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 320px;
    gap: 10px;
    text-align: center;
    padding: 48px 32px;
  }

  .empty-icon {
    color: rgba(255, 255, 255, 0.1);
    margin-bottom: 4px;
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
    line-height: 1.5;
  }

  .empty-cta {
    margin-top: 8px;
    padding: 8px 18px;
    border-radius: var(--radius-full);
    border: 1px solid rgba(255, 255, 255, 0.12);
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-secondary);
    font-size: 0.8125rem;
    font-weight: 500;
    transition: background 0.15s, border-color 0.15s, color 0.15s;
  }

  .empty-cta:hover {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
  }

  /* ── Error banner ── */

  .error-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 20px;
    background: rgba(239, 68, 68, 0.06);
    border-top: 1px solid rgba(239, 68, 68, 0.15);
    font-size: 0.75rem;
    color: rgba(239, 68, 68, 0.8);
    flex-shrink: 0;
  }

  .error-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(239, 68, 68, 0.7);
    flex-shrink: 0;
  }

  .error-text {
    flex: 1;
    min-width: 0;
  }

  .error-dismiss {
    flex-shrink: 0;
    padding: 3px 10px;
    background: rgba(239, 68, 68, 0.1);
    border: 1px solid rgba(239, 68, 68, 0.2);
    border-radius: var(--radius-full);
    color: rgba(239, 68, 68, 0.8);
    font-size: 0.6875rem;
    font-weight: 500;
    transition: background 0.12s;
  }

  .error-dismiss:hover {
    background: rgba(239, 68, 68, 0.18);
  }
</style>
