<script lang="ts">
  interface Agent {
    agent_name: string;
    spent_daily_cents: number;
    budget_daily_cents: number;
    spent_monthly_cents: number;
    budget_monthly_cents: number;
    status: string;
  }

  interface Props {
    dailySpent: number;
    dailyLimit: number;
    monthlySpent: number;
    monthlyLimit: number;
    agents: Agent[];
    loading?: boolean;
  }

  let { dailySpent, dailyLimit, monthlySpent, monthlyLimit, agents, loading = false }: Props = $props();

  function pct(spent: number, limit: number): number {
    if (limit === 0) return 0;
    return Math.min((spent / limit) * 100, 100);
  }

  function barColor(p: number): string {
    if (p >= 95) return "var(--accent-error)";
    if (p >= 80) return "var(--accent-warning)";
    return "var(--accent-success)";
  }

  function fmt(cents: number): string {
    return `$${(cents / 100).toFixed(2)}`;
  }

  let dailyPct = $derived(pct(dailySpent, dailyLimit));
  let monthlyPct = $derived(pct(monthlySpent, monthlyLimit));
</script>

<section class="bg-root glass-panel" aria-label="Budget overview">
  {#if loading}
    <div class="bg-skeleton bg-sk-label"></div>
    <div class="bg-skeleton bg-sk-bar"></div>
    <div class="bg-skeleton bg-sk-label" style="margin-top:12px"></div>
    <div class="bg-skeleton bg-sk-bar"></div>
  {:else}
    <div class="bg-row" aria-label="Daily budget: {fmt(dailySpent)} of {fmt(dailyLimit)} ({dailyPct.toFixed(1)}%)">
      <div class="bg-meta">
        <span class="bg-label">Daily</span>
        <span class="bg-amount">{fmt(dailySpent)} / {fmt(dailyLimit)}</span>
        <span class="bg-pct" style="color: {barColor(dailyPct)}">{dailyPct.toFixed(1)}%</span>
      </div>
      <div class="bg-track" aria-hidden="true">
        <div class="bg-fill" style="width: {dailyPct}%; background: {barColor(dailyPct)}"></div>
      </div>
    </div>

    <div class="bg-row" aria-label="Monthly budget: {fmt(monthlySpent)} of {fmt(monthlyLimit)} ({monthlyPct.toFixed(1)}%)">
      <div class="bg-meta">
        <span class="bg-label">Monthly</span>
        <span class="bg-amount">{fmt(monthlySpent)} / {fmt(monthlyLimit)}</span>
        <span class="bg-pct" style="color: {barColor(monthlyPct)}">{monthlyPct.toFixed(1)}%</span>
      </div>
      <div class="bg-track" aria-hidden="true">
        <div class="bg-fill" style="width: {monthlyPct}%; background: {barColor(monthlyPct)}"></div>
      </div>
    </div>

    {#if agents.length > 0}
      <div class="bg-agents" aria-label="Per-agent budget">
        {#each agents as agent (agent.agent_name)}
          {@const dp = pct(agent.spent_daily_cents, agent.budget_daily_cents)}
          <div class="bg-agent-row">
            <div class="bg-agent-header">
              <span class="bg-agent-name">{agent.agent_name}</span>
              {#if agent.status === "paused_budget"}
                <span class="bg-badge-paused" aria-label="Agent paused">paused</span>
              {/if}
              <span class="bg-agent-amt">{fmt(agent.spent_daily_cents)} / {fmt(agent.budget_daily_cents)}</span>
            </div>
            <div class="bg-track bg-track--sm" aria-hidden="true">
              <div class="bg-fill" style="width: {dp}%; background: {barColor(dp)}"></div>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  {/if}
</section>

<style>
  .bg-root { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
  .bg-row { display: flex; flex-direction: column; gap: 6px; }
  .bg-meta { display: flex; align-items: baseline; gap: 8px; }
  .bg-label { font-size: 12px; font-weight: 600; color: var(--text-secondary); width: 52px; flex-shrink: 0; }
  .bg-amount { font-size: 12px; color: var(--text-primary); font-variant-numeric: tabular-nums; flex: 1; }
  .bg-pct { font-size: 11px; font-weight: 600; font-variant-numeric: tabular-nums; }
  .bg-track { height: 8px; background: rgba(255, 255, 255, 0.06); border-radius: var(--radius-full); overflow: hidden; }
  .bg-track--sm { height: 5px; }
  .bg-fill { height: 100%; border-radius: var(--radius-full); transition: width 0.3s ease, background 0.2s ease; }
  .bg-agents { display: flex; flex-direction: column; gap: 8px; padding-top: 8px; border-top: 1px solid var(--border-default); }
  .bg-agent-row { display: flex; flex-direction: column; gap: 4px; }
  .bg-agent-header { display: flex; align-items: center; gap: 6px; }
  .bg-agent-name { font-size: 11px; font-family: var(--font-mono); color: var(--text-secondary); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .bg-agent-amt { font-size: 10px; color: var(--text-tertiary); font-variant-numeric: tabular-nums; white-space: nowrap; }
  .bg-badge-paused { font-size: 9px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; padding: 1px 5px; border-radius: var(--radius-full); background: rgba(245, 158, 11, 0.12); border: 1px solid rgba(245, 158, 11, 0.25); color: var(--accent-warning); }
  .bg-skeleton { border-radius: var(--radius-sm); background: rgba(255, 255, 255, 0.06); animation: bg-shimmer 1.4s ease-in-out infinite; }
  .bg-sk-label { height: 12px; width: 180px; }
  .bg-sk-bar { height: 8px; width: 100%; border-radius: var(--radius-full); animation-delay: 0.1s; }
  @keyframes bg-shimmer { 0%, 100% { opacity: 0.5; } 50% { opacity: 1; } }
  @media (prefers-reduced-motion: reduce) { .bg-fill { transition: none; } .bg-skeleton { animation: none; } }
</style>
