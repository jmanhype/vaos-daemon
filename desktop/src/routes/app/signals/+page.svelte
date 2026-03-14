<script lang="ts">
  import { onMount, onDestroy } from "svelte";
  import { signalsStore } from "$lib/stores/signals.svelte";
  import SignalModeBar from "$lib/components/signals/SignalModeBar.svelte";
  import SignalWeightGauge from "$lib/components/signals/SignalWeightGauge.svelte";
  import SignalFeed from "$lib/components/signals/SignalFeed.svelte";
  import SignalFilters from "$lib/components/signals/SignalFilters.svelte";
  import SignalChannelBreakdown from "$lib/components/signals/SignalChannelBreakdown.svelte";
  import SignalTypeBreakdown from "$lib/components/signals/SignalTypeBreakdown.svelte";
  import SignalPatterns from "$lib/components/signals/SignalPatterns.svelte";

  function handleModeSelect(mode: string | undefined): void {
    signalsStore.setFilter('mode', mode);
    signalsStore.fetchSignals();
  }

  function handleFilter(key: string, value: string | undefined): void {
    signalsStore.setFilter(key as 'mode' | 'type' | 'channel', value);
    signalsStore.fetchSignals();
  }

  function handleClearFilters(): void {
    signalsStore.clearFilters();
    signalsStore.fetchSignals();
  }

  onMount(() => {
    signalsStore.fetchSignals();
    signalsStore.fetchStats();
    signalsStore.fetchPatterns();
    signalsStore.subscribeLive();
  });

  onDestroy(() => {
    signalsStore.unsubscribeLive();
  });
</script>

<div class="signals-page">
  <header class="page-header">
    <div class="header-left">
      <div class="header-title-group">
        <h1 class="page-title">Signals</h1>
        <p class="page-subtitle">Signal classification and routing intelligence</p>
      </div>
    </div>

    <div class="header-actions">
      <SignalFilters
        filters={signalsStore.filters}
        onFilter={handleFilter}
        onClear={handleClearFilters}
      />

      <button
        class="action-btn action-btn--secondary action-btn--icon"
        onclick={() => { signalsStore.fetchSignals(); signalsStore.fetchStats(); signalsStore.fetchPatterns(); }}
        disabled={signalsStore.loading}
        aria-label="Refresh signals"
        title="Refresh"
      >
        <svg
          width="13"
          height="13"
          viewBox="0 0 13 13"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
          class:spin={signalsStore.loading}
        >
          <path d="M11 6.5A4.5 4.5 0 002 6.5"/>
          <path d="M11 4.5v2H9"/>
        </svg>
      </button>
    </div>
  </header>

  <main class="page-content" id="signals-main">
    {#if signalsStore.error}
      <div class="status-banner" role="status">
        <span class="status-dot" aria-hidden="true"></span>
        <span class="status-text">Backend offline — no signal data</span>
        <button
          class="status-action"
          onclick={() => signalsStore.fetchSignals()}
          aria-label="Retry fetching signals"
        >
          Retry
        </button>
      </div>
    {/if}

    <section class="mode-section">
      <SignalModeBar
        stats={signalsStore.stats}
        activeMode={signalsStore.filters.mode}
        onModeSelect={handleModeSelect}
      />
    </section>

    <div class="content-grid">
      <div class="left-col">
        <div class="panel">
          <SignalWeightGauge stats={signalsStore.stats} />
        </div>

        <div class="panel">
          <SignalChannelBreakdown stats={signalsStore.stats} />
        </div>

        <div class="panel">
          <SignalTypeBreakdown stats={signalsStore.stats} />
        </div>

        <div class="panel">
          <SignalPatterns patterns={signalsStore.patterns} />
        </div>
      </div>

      <div class="right-col">
        <SignalFeed
          signals={signalsStore.liveFeed.length > 0 ? signalsStore.liveFeed : signalsStore.signals}
          connected={signalsStore.liveConnected}
        />
      </div>
    </div>
  </main>
</div>

<style>
  .signals-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  .page-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 24px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
    gap: 16px;
    flex-wrap: wrap;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 12px;
    min-width: 0;
  }

  .header-title-group {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .page-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.01em;
  }

  .page-subtitle {
    font-size: 0.75rem;
    color: var(--text-tertiary);
    line-height: 1;
  }

  .header-actions {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
  }

  .action-btn {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 6px 12px;
    border-radius: var(--radius-sm);
    border: 1px solid transparent;
    font-size: 0.75rem;
    font-weight: 500;
    transition: all 0.15s;
    white-space: nowrap;
    line-height: 1;
  }

  .action-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .action-btn--secondary {
    background: rgba(255, 255, 255, 0.05);
    border-color: rgba(255, 255, 255, 0.08);
    color: var(--text-secondary);
  }

  .action-btn--secondary:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.09);
    border-color: rgba(255, 255, 255, 0.14);
    color: var(--text-primary);
  }

  .action-btn--icon {
    padding: 6px 8px;
  }

  :global(.spin) {
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .page-content {
    flex: 1;
    overflow-y: auto;
    padding: 0 24px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .status-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 14px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md);
    font-size: 0.7rem;
    color: var(--text-tertiary);
    margin-top: 8px;
    flex-shrink: 0;
  }

  .status-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .status-text {
    color: var(--text-secondary);
    font-size: 0.7rem;
  }

  .status-action {
    margin-left: auto;
    padding: 3px 10px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.65rem;
    font-weight: 500;
    transition: background 0.15s, border-color 0.15s;
    flex-shrink: 0;
  }

  .status-action:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
  }

  .mode-section {
    margin-top: 16px;
    flex-shrink: 0;
  }

  .content-grid {
    display: grid;
    grid-template-columns: 1fr 2fr;
    gap: 16px;
    flex: 1;
    min-height: 0;
  }

  .left-col {
    display: flex;
    flex-direction: column;
    gap: 16px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .panel {
    padding: 14px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
  }

  .right-col {
    display: flex;
    flex-direction: column;
    min-height: 0;
    padding: 14px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
  }
</style>
