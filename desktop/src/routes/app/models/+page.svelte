<!-- src/routes/app/models/+page.svelte -->
<!-- Model browser — grouped by provider, searchable, glassmorphic. -->
<script lang="ts">
  import { onMount } from 'svelte';
  import { modelsStore } from '$lib/stores/models.svelte';
  import { restartBackend } from '$lib/utils/backend';
  import type { Model } from '$lib/api/types';

  // ── State ──────────────────────────────────────────────────────────────────

  let query = $state('');
  let collapsedProviders = $state<Set<string>>(new Set());

  // ── Derived ────────────────────────────────────────────────────────────────

  let groups = $derived(modelsStore.searchFiltered(query));
  let current = $derived(modelsStore.current);
  let currentLabel = $derived(modelsStore.currentLabel);
  let switching = $derived(modelsStore.switching);
  let switchError = $derived(modelsStore.switchError);

  // ── Helpers ────────────────────────────────────────────────────────────────

  function formatContext(ctx: number): string {
    if (ctx >= 1_000_000) return `${(ctx / 1_000_000).toFixed(0)}M ctx`;
    if (ctx >= 1_000) return `${Math.round(ctx / 1_000)}K ctx`;
    return `${ctx} ctx`;
  }

  function modelCapabilities(model: Model): string[] {
    const caps: string[] = [];
    const name = model.name.toLowerCase();
    const desc = (model.description ?? '').toLowerCase();

    if (name.includes('vision') || desc.includes('vision') || desc.includes('image') || desc.includes('multimodal')) {
      caps.push('vision');
    }
    if (
      name.includes('reason') || desc.includes('reason') ||
      name.includes('thinking') || desc.includes('thinking') ||
      name.includes('r1') || name.includes('o1') || name.includes('o3') || name.includes('o4') ||
      name.includes('qwq')
    ) {
      caps.push('reasoning');
    }
    if (name.includes('code') || desc.includes('code') || desc.includes('coding')) {
      caps.push('code');
    }
    if (desc.includes('tool use') || desc.includes('tool_use') ||
        name.includes('claude') || name.includes('gpt-4') || name.includes('llama-3.3') || name.includes('llama-4')) {
      caps.push('tool use');
    }
    if (model.context_window >= 100_000) {
      caps.push('long ctx');
    }
    if (model.is_local) {
      caps.push('local');
    }
    if (model.requires_api_key && !model.is_local) {
      caps.push('cloud');
    }
    return caps;
  }

  function modelStatus(model: Model): 'active' | 'available' | 'unreachable' {
    if (model.active) return 'active';
    // Treat models that require an API key but are cloud providers as always
    // reachable — the backend will surface auth errors separately.
    return 'available';
  }

  function toggleProvider(slug: string) {
    const next = new Set(collapsedProviders);
    if (next.has(slug)) {
      next.delete(slug);
    } else {
      next.add(slug);
    }
    collapsedProviders = next;
  }

  function isCollapsed(slug: string): boolean {
    return collapsedProviders.has(slug);
  }

  async function handleActivate(model: Model) {
    if (model.active || switching === model.name) return;
    await modelsStore.activateModel(model.name);
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  onMount(() => {
    modelsStore.fetchModels();
  });
</script>

<svelte:head>
  <title>Models — OSA</title>
</svelte:head>

<div class="mb-root" aria-label="Model browser">

  <!-- ── Header ─────────────────────────────────────────────────────────── -->
  <header class="mb-header">
    <div class="mb-header-left">
      <h1 class="mb-title">Models</h1>
      {#if current}
        <span class="mb-current-badge" aria-label="Active model: {currentLabel}">
          <span class="mb-current-dot" aria-hidden="true"></span>
          {currentLabel}
        </span>
      {/if}
    </div>

    <!-- Search -->
    <div class="mb-search-wrap">
      <svg class="mb-search-icon" width="14" height="14" viewBox="0 0 24 24" fill="none"
           stroke="currentColor" stroke-width="2" aria-hidden="true">
        <circle cx="11" cy="11" r="8"/>
        <path stroke-linecap="round" d="M21 21l-4.35-4.35"/>
      </svg>
      <input
        class="mb-search glass-input"
        type="search"
        placeholder="Search models..."
        aria-label="Search models"
        bind:value={query}
      />
    </div>
  </header>

  <!-- ── Recommendation banner ──────────────────────────────────────────── -->
  <div class="mb-recommend" role="note">
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
      <circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/>
    </svg>
    <span>For best agent performance, use models with <strong>tool use</strong>, <strong>code generation</strong>, and <strong>long context</strong> (32K+). Recommended: Claude Opus 4.6 / Sonnet 4.6, GPT-4.1, Llama 3.3 70B, o3/o4-mini for reasoning. Configure API keys in Settings to unlock cloud models.</span>
  </div>

  <!-- ── Error banner ───────────────────────────────────────────────────── -->
  {#if modelsStore.error}
    <div class="mb-status-banner" role="status">
      <span class="mb-status-dot-indicator"></span>
      <span class="mb-status-text">Backend offline</span>
      <span class="mb-status-hint">Start OSA backend on port 9089</span>
      <button
        class="mb-restart-btn"
        onclick={() => { restartBackend().then(() => modelsStore.fetchModels()).catch(() => {}); }}
        aria-label="Restart backend"
      >
        Restart
      </button>
      <button
        class="mb-restart-btn"
        onclick={() => modelsStore.fetchModels()}
        aria-label="Retry"
      >
        Retry
      </button>
    </div>
  {/if}

  {#if switchError}
    <div class="mb-status-banner" role="alert">
      <span class="mb-status-dot-indicator"></span>
      <span class="mb-status-text">{switchError}</span>
    </div>
  {/if}

  <!-- ── Loading skeleton ───────────────────────────────────────────────── -->
  {#if modelsStore.loading}
    <div class="mb-loading" aria-label="Loading models" aria-busy="true">
      {#each [1, 2, 3] as _}
        <div class="mb-skeleton-section glass-panel">
          <div class="mb-skeleton-header"></div>
          <div class="mb-skeleton-row"></div>
          <div class="mb-skeleton-row mb-skeleton-row--short"></div>
          <div class="mb-skeleton-row"></div>
        </div>
      {/each}
    </div>

  <!-- ── Empty state ────────────────────────────────────────────────────── -->
  {:else if groups.length === 0}
    <div class="mb-empty glass-panel">
      <svg class="mb-empty-icon" width="40" height="40" viewBox="0 0 24 24" fill="none"
           stroke="currentColor" stroke-width="1.5" aria-hidden="true">
        <rect x="2" y="3" width="20" height="14" rx="2"/>
        <path d="M8 21h8m-4-4v4"/>
      </svg>
      {#if query}
        <p class="mb-empty-title">No models match "{query}"</p>
        <p class="mb-empty-sub">Try a different search term.</p>
      {:else}
        <p class="mb-empty-title">No models available</p>
        <p class="mb-empty-sub">Configure a provider in Settings to get started.</p>
      {/if}
    </div>

  <!-- ── Provider sections ─────────────────────────────────────────────── -->
  {:else}
    <div class="mb-sections">
      {#each groups as group (group.meta.slug)}
        <section class="mb-provider glass-panel" aria-label="{group.meta.label} models">

          <!-- Provider header -->
          <button
            class="mb-provider-header"
            aria-expanded={!isCollapsed(group.meta.slug)}
            aria-controls="mb-models-{group.meta.slug}"
            onclick={() => toggleProvider(group.meta.slug)}
          >
            <!-- Icon circle -->
            <span
              class="mb-provider-icon"
              style="background: {group.meta.color}20; color: {group.meta.color}; border-color: {group.meta.color}40"
              aria-hidden="true"
            >
              {group.meta.letter}
            </span>

            <span class="mb-provider-name">{group.meta.label}</span>

            <!-- Model count -->
            <span class="mb-count-badge" aria-label="{group.models.length} models">
              {group.models.length}
            </span>

            <!-- Availability dot -->
            <span
              class="mb-avail-dot"
              class:mb-avail-dot--active={group.available}
              aria-label={group.available ? 'Has active model' : 'No active model'}
            ></span>

            <!-- Chevron -->
            <svg
              class="mb-chevron"
              class:mb-chevron--collapsed={isCollapsed(group.meta.slug)}
              width="14" height="14" viewBox="0 0 24 24" fill="none"
              stroke="currentColor" stroke-width="2" aria-hidden="true"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7"/>
            </svg>
          </button>

          <!-- Model list -->
          {#if !isCollapsed(group.meta.slug)}
            <ul
              class="mb-model-list"
              id="mb-models-{group.meta.slug}"
              role="list"
            >
              {#each group.models as model (model.name)}
                {@const status = modelStatus(model)}
                {@const caps = modelCapabilities(model)}
                {@const isActive = model.active}
                {@const isSwitching = switching === model.name}

                <li
                  class="mb-model-row"
                  class:mb-model-row--active={isActive}
                  aria-label="{model.name}{isActive ? ' (active)' : ''}"
                >
                  <!-- Left: name + badges -->
                  <div class="mb-model-info">
                    <div class="mb-model-name-row">
                      <span class="mb-model-name">{model.name}</span>
                      {#if model.size}
                        <span class="mb-model-size">{model.size}</span>
                      {/if}
                    </div>
                    {#if model.description}
                      <span class="mb-model-desc">{model.description}</span>
                    {/if}

                    <div class="mb-model-badges" aria-label="Model details">
                      <!-- Context window -->
                      <span class="mb-badge mb-badge--ctx" aria-label="Context window: {model.context_window}">
                        {formatContext(model.context_window)}
                      </span>

                      <!-- Capability badges -->
                      {#each caps as cap}
                        <span class="mb-badge mb-badge--cap">{cap}</span>
                      {/each}

                      <!-- Status badge -->
                      {#if status === 'active'}
                        <span class="mb-badge mb-badge--active" aria-label="Currently active">
                          <span class="mb-status-dot mb-status-dot--active" aria-hidden="true"></span>
                          active
                        </span>
                      {:else if status === 'unreachable'}
                        <span class="mb-badge mb-badge--unreachable" aria-label="Model unreachable">
                          <span class="mb-status-dot mb-status-dot--unreachable" aria-hidden="true"></span>
                          unreachable
                        </span>
                      {/if}
                    </div>
                  </div>

                  <!-- Right: Use button -->
                  <div class="mb-model-actions">
                    {#if isActive}
                      <span class="mb-in-use" aria-label="This model is in use">In use</span>
                    {:else}
                      <button
                        class="mb-use-btn"
                        aria-label="Use {model.name}"
                        disabled={isSwitching || switching !== null}
                        onclick={() => handleActivate(model)}
                      >
                        {#if isSwitching}
                          <span class="mb-spinner" aria-hidden="true"></span>
                          Switching…
                        {:else}
                          Use
                        {/if}
                      </button>
                    {/if}
                  </div>
                </li>
              {/each}
            </ul>
          {/if}
        </section>
      {/each}
    </div>
  {/if}

</div>

<style>
  /* ── Page root ─────────────────────────────────────────────────────────── */
  .mb-root {
    display: flex;
    flex-direction: column;
    height: 100%;
    padding: 24px;
    gap: 16px;
    overflow-x: hidden;
    overflow-y: auto;
  }

  /* ── Header ────────────────────────────────────────────────────────────── */
  .mb-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    flex-shrink: 0;
  }

  .mb-header-left {
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
  }

  .mb-title {
    font-size: 20px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.02em;
    flex-shrink: 0;
  }

  .mb-current-badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 10px;
    background: rgba(59, 130, 246, 0.1);
    border: 1px solid rgba(59, 130, 246, 0.25);
    border-radius: var(--radius-full);
    font-size: 11px;
    font-weight: 500;
    color: #93bbfd;
    font-family: var(--font-mono);
    max-width: 280px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .mb-current-dot {
    width: 6px;
    height: 6px;
    border-radius: 9999px;
    background: var(--accent-success);
    flex-shrink: 0;
    animation: mb-pulse 2s ease-in-out infinite;
  }

  /* ── Search ────────────────────────────────────────────────────────────── */
  .mb-search-wrap {
    position: relative;
    width: 220px;
    flex-shrink: 0;
  }

  .mb-search-icon {
    position: absolute;
    left: 12px;
    top: 50%;
    transform: translateY(-50%);
    color: var(--text-tertiary);
    pointer-events: none;
  }

  .mb-search {
    padding-left: 34px;
  }

  /* ── Status banner (subtle, not alarming) ──────────────────────────────── */
  .mb-recommend {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    padding: 10px 16px;
    margin: 0 16px 8px;
    font-size: 0.75rem;
    line-height: 1.5;
    color: rgba(255, 255, 255, 0.45);
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 10px;
    flex-shrink: 0;
  }

  .mb-recommend svg {
    flex-shrink: 0;
    margin-top: 1px;
    color: rgba(255, 255, 255, 0.3);
  }

  .mb-recommend strong {
    color: rgba(255, 255, 255, 0.65);
    font-weight: 600;
  }

  .mb-status-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 16px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md);
    font-size: 0.7rem;
    color: var(--text-tertiary);
    flex-shrink: 0;
  }

  .mb-status-dot-indicator {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .mb-status-text {
    color: var(--text-secondary);
  }

  .mb-status-hint {
    margin-left: auto;
    color: var(--text-muted);
  }

  .mb-restart-btn {
    padding: 3px 10px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.65rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
    flex-shrink: 0;
  }

  .mb-restart-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
  }

  /* ── Loading skeletons ─────────────────────────────────────────────────── */
  .mb-loading {
    display: flex;
    flex-direction: column;
    gap: 8px;
    overflow: hidden;
  }

  .mb-skeleton-section {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .mb-skeleton-header {
    height: 20px;
    width: 160px;
    border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.06);
    animation: mb-shimmer 1.4s ease-in-out infinite;
  }

  .mb-skeleton-row {
    height: 16px;
    width: 100%;
    border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.04);
    animation: mb-shimmer 1.4s ease-in-out infinite 0.1s;
  }

  .mb-skeleton-row--short {
    width: 60%;
    animation-delay: 0.2s;
  }

  /* ── Empty state ───────────────────────────────────────────────────────── */
  .mb-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    padding: 64px 24px;
    text-align: center;
  }

  .mb-empty-icon {
    color: var(--text-tertiary);
    margin-bottom: 4px;
  }

  .mb-empty-title {
    font-size: 15px;
    font-weight: 600;
    color: var(--text-secondary);
  }

  .mb-empty-sub {
    font-size: 13px;
    color: var(--text-tertiary);
  }

  /* ── Sections container ────────────────────────────────────────────────── */
  .mb-sections {
    display: flex;
    flex-direction: column;
    gap: 8px;
    /* No flex:1 / min-height:0 here — let .mb-root (overflow-y:auto) scroll */
    padding-right: 2px;
    padding-bottom: 24px;
  }

  /* ── Provider section ──────────────────────────────────────────────────── */
  .mb-provider {
    /* Override glass-panel padding — we control layout ourselves */
    padding: 0;
    overflow: hidden;
    transition: border-color 0.15s ease;
  }

  .mb-provider-header {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 12px 16px;
    background: transparent;
    border: none;
    color: var(--text-primary);
    cursor: pointer;
    text-align: left;
    transition: background 0.15s ease;
  }

  .mb-provider-header:hover {
    background: rgba(255, 255, 255, 0.03);
  }

  .mb-provider-header:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: -2px;
  }

  .mb-provider-icon {
    width: 28px;
    height: 28px;
    border-radius: var(--radius-sm);
    border: 1px solid;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 13px;
    font-weight: 700;
    flex-shrink: 0;
    letter-spacing: 0;
  }

  .mb-provider-name {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
    flex: 1;
  }

  .mb-count-badge {
    font-size: 11px;
    font-weight: 500;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-full);
    padding: 1px 7px;
  }

  .mb-avail-dot {
    width: 7px;
    height: 7px;
    border-radius: 9999px;
    background: rgba(255, 255, 255, 0.15);
    flex-shrink: 0;
  }

  .mb-avail-dot--active {
    background: var(--accent-success);
  }

  .mb-chevron {
    color: var(--text-tertiary);
    flex-shrink: 0;
    transition: transform 0.2s ease;
  }

  .mb-chevron--collapsed {
    transform: rotate(-90deg);
  }

  /* ── Model list ─────────────────────────────────────────────────────────── */
  .mb-model-list {
    list-style: none;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
  }

  .mb-model-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 11px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    transition: background 0.15s ease, border-left-color 0.15s ease;
    border-left: 2px solid transparent;
  }

  .mb-model-row:last-child {
    border-bottom: none;
  }

  .mb-model-row:hover {
    background: rgba(255, 255, 255, 0.025);
  }

  .mb-model-row--active {
    border-left-color: var(--accent-primary);
    background: rgba(59, 130, 246, 0.04);
  }

  .mb-model-row--active:hover {
    background: rgba(59, 130, 246, 0.07);
  }

  /* ── Model info ─────────────────────────────────────────────────────────── */
  .mb-model-info {
    display: flex;
    flex-direction: column;
    gap: 5px;
    min-width: 0;
    flex: 1;
  }

  .mb-model-name-row {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }

  .mb-model-name {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
    font-family: var(--font-mono);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .mb-model-size {
    font-size: 11px;
    font-weight: 500;
    color: var(--text-tertiary);
    white-space: nowrap;
    flex-shrink: 0;
  }

  .mb-model-desc {
    font-size: 11px;
    line-height: 1.4;
    color: var(--text-muted, rgba(255, 255, 255, 0.35));
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    max-width: 500px;
  }

  .mb-model-badges {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    align-items: center;
  }

  /* ── Badges ─────────────────────────────────────────────────────────────── */
  .mb-badge {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px 7px;
    border-radius: var(--radius-full);
    font-size: 10px;
    font-weight: 500;
    border: 1px solid transparent;
  }

  .mb-badge--ctx {
    background: rgba(255, 255, 255, 0.06);
    border-color: rgba(255, 255, 255, 0.08);
    color: var(--text-secondary);
    font-family: var(--font-mono);
  }

  .mb-badge--cap {
    background: rgba(255, 255, 255, 0.04);
    border-color: rgba(255, 255, 255, 0.06);
    color: var(--text-tertiary);
  }


  .mb-badge--active {
    background: rgba(34, 197, 94, 0.1);
    border-color: rgba(34, 197, 94, 0.2);
    color: #86efac;
  }

  .mb-badge--unreachable {
    background: rgba(239, 68, 68, 0.08);
    border-color: rgba(239, 68, 68, 0.18);
    color: #fca5a5;
  }

  .mb-status-dot {
    width: 5px;
    height: 5px;
    border-radius: 9999px;
  }

  .mb-status-dot--active {
    background: var(--accent-success);
    animation: mb-pulse 2s ease-in-out infinite;
  }

  .mb-status-dot--unreachable {
    background: var(--accent-error);
  }

  /* ── Model actions ──────────────────────────────────────────────────────── */
  .mb-model-actions {
    flex-shrink: 0;
  }

  .mb-in-use {
    font-size: 11px;
    font-weight: 500;
    color: var(--text-tertiary);
    padding: 0 4px;
  }

  .mb-use-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 5px 14px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: var(--radius-full);
    font-size: 12px;
    font-weight: 600;
    color: var(--text-primary);
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease, opacity 0.15s ease;
    white-space: nowrap;
  }

  .mb-use-btn:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.18);
  }

  .mb-use-btn:active:not(:disabled) {
    transform: scale(0.97);
  }

  .mb-use-btn:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: 2px;
  }

  .mb-use-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  /* ── Spinner ────────────────────────────────────────────────────────────── */
  .mb-spinner {
    width: 10px;
    height: 10px;
    border-radius: 9999px;
    border: 2px solid rgba(255, 255, 255, 0.15);
    border-top-color: rgba(255, 255, 255, 0.7);
    animation: mb-spin 0.7s linear infinite;
  }

  /* ── Keyframes ──────────────────────────────────────────────────────────── */
  @keyframes mb-pulse {
    0%, 100% { opacity: 1; }
    50%       { opacity: 0.4; }
  }

  @keyframes mb-spin {
    to { transform: rotate(360deg); }
  }

  @keyframes mb-shimmer {
    0%, 100% { opacity: 0.6; }
    50%       { opacity: 1; }
  }

  @media (prefers-reduced-motion: reduce) {
    .mb-current-dot,
    .mb-status-dot--active {
      animation: none;
    }
    .mb-spinner {
      animation: none;
      border-top-color: rgba(255, 255, 255, 0.5);
    }
  }
</style>
