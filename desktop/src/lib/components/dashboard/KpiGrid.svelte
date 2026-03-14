<script lang="ts">
  import StatCard from "$lib/components/usage/StatCard.svelte";
  import type { DashboardKpis } from "$api/types";

  interface Props {
    kpis: DashboardKpis;
    loading?: boolean;
  }

  let { kpis, loading = false }: Props = $props();

  const tokensDisplay = $derived(formatTokens(kpis.tokens_used_today));

  function formatTokens(n: number): string {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
    return String(n);
  }

  // SVG icon paths (stroke-based, 24x24 viewBox)
  const icons = {
    sessions: "M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z",
    agents: "M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2 M23 21v-2a4 4 0 0 0-3-3.87 M16 3.13a4 4 0 0 1 0 7.75 M9 7a4 4 0 1 0 0-0.01",
    signals: "M13 2L3 14h9l-1 8 10-12h-9l1-8",
    tasks: "M9 11l3 3L22 4 M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11",
    tokens: "M12 2v20 M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6",
    pending: "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20 M12 6v6l4 2",
  };
</script>

<div class="kpi-grid">
  <StatCard
    label="Active Sessions"
    value={kpis.active_sessions}
    icon={icons.sessions}
    {loading}
  />
  <StatCard
    label="Agents Online"
    value="{kpis.agents_online} / {kpis.agents_total}"
    icon={icons.agents}
    {loading}
  />
  <StatCard
    label="Signals Today"
    value={kpis.signals_today}
    icon={icons.signals}
    {loading}
  />
  <StatCard
    label="Tasks Done"
    value={kpis.tasks_completed}
    subtitle="{kpis.tasks_pending} pending"
    icon={icons.tasks}
    {loading}
  />
  <StatCard
    label="Tokens Used"
    value={tokensDisplay}
    icon={icons.tokens}
    {loading}
  />
  <StatCard
    label="Pending"
    value={kpis.tasks_pending}
    icon={icons.pending}
    {loading}
  />
</div>

<style>
  .kpi-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 12px;
  }

  @media (max-width: 900px) {
    .kpi-grid {
      grid-template-columns: repeat(2, 1fr);
    }
  }
</style>
