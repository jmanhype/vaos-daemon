<script lang="ts">
  import type { SignalStats } from "$lib/api/types";

  interface Props {
    stats: SignalStats | null;
  }

  let { stats }: Props = $props();

  const entries = $derived.by(() => {
    if (!stats) return [];
    return Object.entries(stats.by_channel)
      .sort(([, a], [, b]) => b - a);
  });

  const maxCount = $derived(
    entries.length > 0 ? entries[0][1] : 1,
  );
</script>

<div class="breakdown">
  <span class="breakdown-title">By Channel</span>
  <div class="breakdown-list">
    {#each entries as [channel, count] (channel)}
      <div class="breakdown-row">
        <span class="breakdown-label">{channel}</span>
        <div class="breakdown-bar-track">
          <div
            class="breakdown-bar"
            style:width="{(count / maxCount) * 100}%"
          ></div>
        </div>
        <span class="breakdown-count">{count}</span>
      </div>
    {/each}
    {#if entries.length === 0}
      <span class="breakdown-empty">No data</span>
    {/if}
  </div>
</div>

<style>
  .breakdown {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .breakdown-title {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .breakdown-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .breakdown-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .breakdown-label {
    width: 60px;
    font-size: 0.65rem;
    color: var(--text-tertiary);
    text-transform: capitalize;
    flex-shrink: 0;
  }

  .breakdown-bar-track {
    flex: 1;
    height: 6px;
    background: rgba(255, 255, 255, 0.04);
    border-radius: var(--radius-full);
    overflow: hidden;
  }

  .breakdown-bar {
    height: 100%;
    background: var(--accent-primary);
    border-radius: var(--radius-full);
    transition: width var(--transition-normal);
    min-width: 2px;
  }

  .breakdown-count {
    width: 28px;
    text-align: right;
    font-size: 0.65rem;
    font-family: var(--font-mono);
    color: var(--text-secondary);
    flex-shrink: 0;
  }

  .breakdown-empty {
    font-size: 0.7rem;
    color: var(--text-muted);
  }
</style>
