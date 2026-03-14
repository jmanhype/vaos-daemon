<script lang="ts">
  import type { Signal } from "$lib/api/types";
  import SignalCard from "./SignalCard.svelte";

  interface Props {
    signals: Signal[];
    connected: boolean;
  }

  let { signals, connected }: Props = $props();

  let feedEl: HTMLDivElement | undefined = $state();
  let userScrolled = $state(false);

  function handleScroll(): void {
    if (!feedEl) return;
    userScrolled = feedEl.scrollTop > 40;
  }

  $effect(() => {
    if (signals.length && feedEl && !userScrolled) {
      feedEl.scrollTop = 0;
    }
  });
</script>

<div class="feed-container">
  <div class="feed-header">
    <span class="feed-title">Live Feed</span>
    <span class="feed-status">
      {#if connected}
        <span class="pulse-dot"></span>
        <span class="status-text">Live</span>
      {:else}
        <span class="offline-dot"></span>
        <span class="status-text">Offline</span>
      {/if}
    </span>
  </div>

  <div
    class="feed-list"
    bind:this={feedEl}
    onscroll={handleScroll}
    role="log"
    aria-label="Live signal feed"
    aria-live="polite"
  >
    {#if signals.length === 0}
      <div class="feed-empty">
        <span class="empty-text">No signals yet</span>
      </div>
    {:else}
      {#each signals as signal (signal.id)}
        <SignalCard {signal} />
      {/each}
    {/if}
  </div>
</div>

<style>
  .feed-container {
    display: flex;
    flex-direction: column;
    height: 100%;
    min-height: 0;
  }

  .feed-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0 0 8px;
    flex-shrink: 0;
  }

  .feed-title {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .feed-status {
    display: flex;
    align-items: center;
    gap: 5px;
  }

  .pulse-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--accent-success);
    animation: pulse 2s ease-in-out infinite;
  }

  .offline-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text-muted);
  }

  .status-text {
    font-size: 0.65rem;
    color: var(--text-tertiary);
  }

  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.4; }
  }

  .feed-list {
    flex: 1;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 2px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .feed-empty {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 48px 0;
  }

  .empty-text {
    font-size: 0.75rem;
    color: var(--text-muted);
  }
</style>
