<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { dashboardStore } from '$lib/stores/dashboard.svelte';
  import SystemHealthBar from '$lib/components/dashboard/SystemHealthBar.svelte';
  import KpiGrid from '$lib/components/dashboard/KpiGrid.svelte';
  import RecentActivityFeed from '$lib/components/dashboard/RecentActivityFeed.svelte';
  import ActiveAgentsPanel from '$lib/components/dashboard/ActiveAgentsPanel.svelte';

  let cleanup: (() => void) | undefined;

  onMount(() => {
    cleanup = dashboardStore.startAutoRefresh(30_000);
  });

  onDestroy(() => {
    cleanup?.();
  });
</script>

<svelte:head>
  <title>Dashboard — OSA</title>
</svelte:head>

<section class="dash" aria-label="Dashboard">
  <SystemHealthBar
    health={dashboardStore.systemHealth}
    uptimeSeconds={dashboardStore.kpis.uptime_seconds}
  />

  <KpiGrid kpis={dashboardStore.kpis} loading={dashboardStore.loading} />

  {#if !dashboardStore.loading}
    <div class="dash-panels">
      <div class="dash-feed">
        <RecentActivityFeed activities={dashboardStore.recentActivity} />
      </div>
      <div class="dash-agents">
        <ActiveAgentsPanel
          agents={dashboardStore.activeAgents}
          agentsTotal={dashboardStore.kpis.agents_total}
        />
      </div>
    </div>
  {/if}

  {#if dashboardStore.error}
    <p class="dash-error" role="alert">{dashboardStore.error}</p>
  {/if}
</section>

<style>
  .dash {
    display: flex;
    flex-direction: column;
    gap: 16px;
    padding: 16px;
    height: 100%;
    box-sizing: border-box;
    overflow-y: auto;
  }

  .dash-panels {
    display: grid;
    grid-template-columns: 3fr 2fr;
    gap: 12px;
    min-height: 0;
  }

  .dash-feed {
    min-width: 0;
  }

  .dash-agents {
    min-width: 0;
  }

  .dash-error {
    font-size: 12px;
    color: var(--accent-error);
    text-align: center;
    margin: 0;
    padding: 8px;
  }

  @media (max-width: 768px) {
    .dash-panels {
      grid-template-columns: 1fr;
    }
  }
</style>
