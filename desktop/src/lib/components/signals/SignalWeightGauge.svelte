<script lang="ts">
  import type { SignalStats } from "$lib/api/types";

  interface Props {
    stats: SignalStats | null;
  }

  let { stats }: Props = $props();

  const tiers = [
    { key: 'haiku', label: 'Haiku', color: 'var(--tier-haiku)' },
    { key: 'sonnet', label: 'Sonnet', color: 'var(--tier-sonnet)' },
    { key: 'opus', label: 'Opus', color: 'var(--tier-opus)' },
  ] as const;

  const total = $derived(
    stats
      ? stats.weight_distribution.haiku +
        stats.weight_distribution.sonnet +
        stats.weight_distribution.opus
      : 0,
  );
</script>

<div class="gauge-container">
  <div class="gauge-label">
    <span class="gauge-title">Weight Distribution</span>
    {#if stats}
      <span class="gauge-avg">avg {stats.avg_weight.toFixed(2)}</span>
    {/if}
  </div>

  <div class="gauge-bar" role="meter" aria-valuenow={stats?.avg_weight ?? 0} aria-valuemin={0} aria-valuemax={1} aria-label="Signal weight distribution">
    {#each tiers as tier (tier.key)}
      {@const count = stats?.weight_distribution[tier.key] ?? 0}
      {@const pct = total > 0 ? (count / total) * 100 : 33.33}
      <div
        class="gauge-segment"
        style:width="{pct}%"
        style:background={tier.color}
        title="{tier.label}: {count}"
      ></div>
    {/each}
  </div>

  <div class="gauge-labels">
    {#each tiers as tier (tier.key)}
      {@const count = stats?.weight_distribution[tier.key] ?? 0}
      <div class="tier-label">
        <span class="tier-dot" style:background={tier.color}></span>
        <span class="tier-name">{tier.label}</span>
        <span class="tier-count">{count}</span>
      </div>
    {/each}
  </div>
</div>

<style>
  .gauge-container {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .gauge-label {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
  }

  .gauge-title {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .gauge-avg {
    font-size: 0.7rem;
    font-family: var(--font-mono);
    color: var(--text-tertiary);
  }

  .gauge-bar {
    display: flex;
    height: 8px;
    border-radius: var(--radius-full);
    overflow: hidden;
    background: rgba(255, 255, 255, 0.04);
    gap: 1px;
  }

  .gauge-segment {
    min-width: 4px;
    transition: width var(--transition-normal);
  }

  .gauge-labels {
    display: flex;
    justify-content: space-between;
  }

  .tier-label {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .tier-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
  }

  .tier-name {
    font-size: 0.65rem;
    color: var(--text-tertiary);
  }

  .tier-count {
    font-size: 0.65rem;
    font-family: var(--font-mono);
    color: var(--text-secondary);
  }
</style>
