<script lang="ts">
  import { fly } from "svelte/transition";

  interface Props {
    dailySpent: number;
    dailyLimit: number;
    monthlySpent: number;
    monthlyLimit: number;
    pausedAgents?: string[];
  }

  let { dailySpent, dailyLimit, monthlySpent, monthlyLimit, pausedAgents = [] }: Props = $props();

  function pct(spent: number, limit: number): number {
    if (limit === 0) return 0;
    return (spent / limit) * 100;
  }

  function fmt(cents: number): string {
    return `$${(cents / 100).toFixed(0)}`;
  }

  let dailyPct = $derived(pct(dailySpent, dailyLimit));
  let monthlyPct = $derived(pct(monthlySpent, monthlyLimit));
  let showDailyWarn = $derived(dailyPct >= 80 && dailyPct < 95);
  let showDailyCrit = $derived(dailyPct >= 95);
  let showMonthWarn = $derived(monthlyPct >= 80 && monthlyPct < 95);
  let showMonthCrit = $derived(monthlyPct >= 95);
  let hasAlerts = $derived(showDailyWarn || showDailyCrit || showMonthWarn || showMonthCrit || pausedAgents.length > 0);
</script>

{#if hasAlerts}
  <div class="ba-stack" role="alert" aria-label="Budget alerts" aria-live="polite">
    {#if showDailyCrit}
      <div class="ba-bar ba-bar--crit" transition:fly={{ y: -8, duration: 200 }}>
        <svg class="ba-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/>
          <line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>
        </svg>
        Daily budget critical — {fmt(dailySpent)} of {fmt(dailyLimit)} used ({dailyPct.toFixed(0)}%)
      </div>
    {:else if showDailyWarn}
      <div class="ba-bar ba-bar--warn" transition:fly={{ y: -8, duration: 200 }}>
        <svg class="ba-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>
        </svg>
        Daily budget at {dailyPct.toFixed(0)}% — {fmt(dailySpent)} of {fmt(dailyLimit)} used
      </div>
    {/if}

    {#if showMonthCrit}
      <div class="ba-bar ba-bar--crit" transition:fly={{ y: -8, duration: 200 }}>
        <svg class="ba-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/>
          <line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>
        </svg>
        Monthly budget critical — {fmt(monthlySpent)} of {fmt(monthlyLimit)} used ({monthlyPct.toFixed(0)}%)
      </div>
    {:else if showMonthWarn}
      <div class="ba-bar ba-bar--warn" transition:fly={{ y: -8, duration: 200 }}>
        <svg class="ba-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>
        </svg>
        Monthly budget at {monthlyPct.toFixed(0)}% — {fmt(monthlySpent)} of {fmt(monthlyLimit)} used
      </div>
    {/if}

    {#each pausedAgents as agent (agent)}
      <div class="ba-bar ba-bar--crit" transition:fly={{ y: -8, duration: 200 }}>
        <svg class="ba-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/>
        </svg>
        Agent paused: <strong>{agent}</strong>
      </div>
    {/each}
  </div>
{/if}

<style>
  .ba-stack { display: flex; flex-direction: column; gap: 4px; }
  .ba-bar { display: flex; align-items: center; gap: 8px; padding: 9px 14px; border-radius: var(--radius-sm); font-size: 12px; font-weight: 500; line-height: 1.4; }
  .ba-bar--warn { background: rgba(245, 158, 11, 0.1); border: 1px solid rgba(245, 158, 11, 0.25); color: #fbbf24; }
  .ba-bar--crit { background: rgba(239, 68, 68, 0.1); border: 1px solid rgba(239, 68, 68, 0.25); color: #f87171; }
  .ba-icon { flex-shrink: 0; }
  strong { font-weight: 700; color: inherit; }
  @media (prefers-reduced-motion: reduce) { .ba-bar { transition: none; } }
</style>
