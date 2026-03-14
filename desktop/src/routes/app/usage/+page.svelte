<!-- src/routes/app/usage/+page.svelte -->
<!-- Usage & Analytics page — stat cards, bar charts, model breakdown. -->
<script lang="ts">
  import { onMount } from "svelte";
  import { usageStore, type AnalyticsPeriod } from "$lib/stores/usage.svelte";
  import StatCard from "$lib/components/usage/StatCard.svelte";
  import UsageChart from "$lib/components/usage/UsageChart.svelte";
  import BudgetOverview from "$lib/components/usage/BudgetOverview.svelte";
  import BudgetAlerts from "$lib/components/usage/BudgetAlerts.svelte";
  import CostBreakdown from "$lib/components/usage/CostBreakdown.svelte";
  import BudgetControls from "$lib/components/usage/BudgetControls.svelte";

  // ── State ──────────────────────────────────────────────────────────────────

  const periods: { label: string; value: AnalyticsPeriod }[] = [
    { label: "7d", value: "7d" },
    { label: "30d", value: "30d" },
    { label: "All", value: "all" },
  ];

  // ── Derived ────────────────────────────────────────────────────────────────

  let stats = $derived(usageStore.stats);
  let loading = $derived(usageStore.loading);
  let error = $derived(usageStore.error);
  let period = $derived(usageStore.period);
  let dailyData = $derived(usageStore.filteredDailyUsage());
  let totalTokensFormatted = $derived(usageStore.totalTokensFormatted());
  let byModel = $derived(stats?.modelUsage ?? []);

  // Max token count for model horizontal bars
  let maxModelTokens = $derived(
    byModel.length === 0 ? 1 : Math.max(...byModel.map((m) => m.tokens), 1),
  );
  let summary = $derived(usageStore.summary);
  let agentBudgets = $derived(usageStore.agentBudgets);
  let costByModel = $derived(usageStore.costByModel);
  let costByAgent = $derived(usageStore.costByAgent);
  let budgetLoading = $derived(usageStore.budgetLoading);
  let pausedAgents = $derived(usageStore.pausedAgents());

  // ── Helpers ────────────────────────────────────────────────────────────────

  function formatResponseTime(ms: number): string {
    if (ms === 0) return "—";
    if (ms < 1000) return `${ms}ms`;
    return `${(ms / 1000).toFixed(1)}s`;
  }

  function modelBarPct(tokens: number): number {
    if (maxModelTokens === 0) return 0;
    return Math.max((tokens / maxModelTokens) * 100, tokens > 0 ? 2 : 0);
  }

  /** Color for model bar — cycles through a palette. */
  function modelColor(i: number): string {
    const colors = [
      "rgba(59, 130, 246, 0.6)",
      "rgba(168, 85, 247, 0.6)",
      "rgba(34, 197, 94, 0.6)",
      "rgba(245, 158, 11, 0.6)",
      "rgba(236, 72, 153, 0.6)",
    ];
    return colors[i % colors.length];
  }

  function modelBorder(i: number): string {
    const borders = [
      "rgba(59, 130, 246, 0.4)",
      "rgba(168, 85, 247, 0.4)",
      "rgba(34, 197, 94, 0.4)",
      "rgba(245, 158, 11, 0.4)",
      "rgba(236, 72, 153, 0.4)",
    ];
    return borders[i % borders.length];
  }

  function formatTokens(n: number): string {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1_000) return `${Math.round(n / 1_000)}K`;
    return String(n);
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  onMount(() => {
    usageStore.fetchUsage();
    usageStore.fetchBudgets();
  });
</script>

<svelte:head>
  <title>Usage — OSA</title>
</svelte:head>

<div class="page-container" aria-label="Usage and analytics">

  <!-- ── Header ─────────────────────────────────────────────────────────── -->
  <header class="page-header">
    <div class="ua-header-left">
      <h1 class="ua-title">Usage & Analytics</h1>
      <p class="ua-subtitle">Message and token activity across sessions</p>
    </div>

    <!-- Period selector -->
    <div class="ua-period-selector" role="group" aria-label="Time period">
      {#each periods as p (p.value)}
        <button
          class="ua-period-btn"
          class:ua-period-btn--active={period === p.value}
          onclick={() => usageStore.setPeriod(p.value)}
          aria-pressed={period === p.value}
          aria-label="View {p.label} period"
        >
          {p.label}
        </button>
      {/each}
    </div>
  </header>

  <!-- ── Content ────────────────────────────────────────────────────────── -->
  <main class="page-content">

    <!-- Error state -->
    {#if error && !stats}
      <div class="ua-error glass-panel" role="alert">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" aria-hidden="true">
          <circle cx="12" cy="12" r="10"/>
          <line x1="12" y1="8" x2="12" y2="12"/>
          <line x1="12" y1="16" x2="12.01" y2="16"/>
        </svg>
        <div class="ua-error-body">
          <p class="ua-error-title">Failed to load usage data</p>
          <p class="ua-error-msg">{error}</p>
        </div>
        <button
          class="ua-retry-btn"
          onclick={() => usageStore.fetchUsage()}
          aria-label="Retry loading usage data"
        >
          Retry
        </button>
      </div>
    {/if}

    <BudgetAlerts dailySpent={summary?.daily_spent_cents ?? 0} dailyLimit={summary?.daily_limit_cents ?? 25000} monthlySpent={summary?.monthly_spent_cents ?? 0} monthlyLimit={summary?.monthly_limit_cents ?? 250000} {pausedAgents} />
    <BudgetOverview dailySpent={summary?.daily_spent_cents ?? 0} dailyLimit={summary?.daily_limit_cents ?? 25000} monthlySpent={summary?.monthly_spent_cents ?? 0} monthlyLimit={summary?.monthly_limit_cents ?? 250000} agents={agentBudgets} loading={budgetLoading} />
    <!-- ── Budget alerts ────────────────────────────────────────────────── -->
    <BudgetAlerts
      dailySpent={summary?.daily_spent_cents ?? 0}
      dailyLimit={summary?.daily_limit_cents ?? 25000}
      monthlySpent={summary?.monthly_spent_cents ?? 0}
      monthlyLimit={summary?.monthly_limit_cents ?? 250000}
      {pausedAgents}
    />

    <!-- ── Budget overview ──────────────────────────────────────────────── -->
    <BudgetOverview
      dailySpent={summary?.daily_spent_cents ?? 0}
      dailyLimit={summary?.daily_limit_cents ?? 25000}
      monthlySpent={summary?.monthly_spent_cents ?? 0}
      monthlyLimit={summary?.monthly_limit_cents ?? 250000}
      agents={agentBudgets}
      loading={budgetLoading}
    />

    <!-- ── Stat cards ──────────────────────────────────────────────────── -->
    <section class="ua-stat-grid" aria-label="Summary statistics">
      <StatCard
        label="Total Messages"
        value={loading ? "" : String(stats?.totalMessages ?? 0)}
        subtitle="across all sessions"
        icon="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"
        {loading}
      />
      <StatCard
        label="Sessions"
        value={loading ? "" : String(stats?.totalSessions ?? 0)}
        subtitle="conversation threads"
        icon="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M23 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"
        {loading}
      />
      <StatCard
        label="Tokens"
        value={loading ? "" : totalTokensFormatted}
        subtitle="total processed"
        icon="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"
        {loading}
      />
      <StatCard
        label="Avg Response Time"
        value={loading ? "" : formatResponseTime(stats?.avgResponseTime ?? 0)}
        subtitle="per message"
        icon="M12 22a10 10 0 1 1 0-20 10 10 0 0 1 0 20zm0-14v4l3 3"
        {loading}
      />
    </section>

    <!-- ── Charts ─────────────────────────────────────────────────────── -->
    <section class="ua-charts" aria-label="Usage charts">

      <!-- Messages chart -->
      <div class="ua-chart-card glass-panel">
        <header class="ua-chart-header">
          <h2 class="ua-chart-title">Messages</h2>
          <span class="ua-chart-period">{period === "all" ? "All time" : `Last ${period}`}</span>
        </header>
        <div class="ua-chart-body">
          <UsageChart data={dailyData} metric="messages" height={180} />
        </div>
      </div>

      <!-- Tokens chart -->
      <div class="ua-chart-card glass-panel">
        <header class="ua-chart-header">
          <h2 class="ua-chart-title">Tokens</h2>
          <span class="ua-chart-period">{period === "all" ? "All time" : `Last ${period}`}</span>
        </header>
        <div class="ua-chart-body">
          <UsageChart data={dailyData} metric="tokens" height={180} />
        </div>
      </div>

    </section>

    <!-- ── Model breakdown ─────────────────────────────────────────────── -->
    <section class="ua-models glass-panel" aria-label="Model usage breakdown">
      <header class="ua-section-header">
        <h2 class="ua-section-title">Model Usage</h2>
        <span class="ua-section-sub">By token volume</span>
      </header>

      {#if loading}
        <!-- Skeleton rows -->
        <div class="ua-model-list">
          {#each [1, 2, 3] as _}
            <div class="ua-model-row">
              <div class="ua-model-sk-name"></div>
              <div class="ua-model-bar-wrap">
                <div class="ua-model-sk-bar"></div>
              </div>
              <div class="ua-model-sk-stat"></div>
            </div>
          {/each}
        </div>

      {:else if byModel.length === 0}
        <div class="ua-models-empty">
          <p>No model data available for this period</p>
        </div>

      {:else}
        <ol class="ua-model-list" aria-label="Models ranked by token usage">
          {#each byModel as model, i (model.model)}
            <li
              class="ua-model-row"
              aria-label="{model.model}: {formatTokens(model.tokens)} tokens, {model.count} messages"
            >
              <!-- Model name + message count -->
              <div class="ua-model-info">
                <span class="ua-model-name">{model.model}</span>
                <span class="ua-model-msgs">{model.count} msgs</span>
              </div>

              <!-- Horizontal bar -->
              <div class="ua-model-bar-wrap" aria-hidden="true">
                <div
                  class="ua-model-bar"
                  style="width: {modelBarPct(model.tokens)}%; background: {modelColor(i)}; border-color: {modelBorder(i)}"
                ></div>
              </div>

              <!-- Token count -->
              <span class="ua-model-tokens">{formatTokens(model.tokens)}</span>
            </li>
          {/each}
        </ol>
      {/if}
    </section>

    <CostBreakdown byModel={costByModel.map(m => ({ model: m.model, cost_cents: m.cost_cents, count: m.count }))} byAgent={costByAgent.map(a => ({ agent_name: a.agent_name, cost_cents: a.cost_cents, count: a.count }))} loading={budgetLoading} />
    <BudgetControls agents={agentBudgets} onUpdate={(name, daily, monthly) => usageStore.updateBudget(name, daily, monthly)} onReset={(name) => usageStore.resetBudget(name)} loading={budgetLoading} />
    <!-- ── Cost breakdown ──────────────────────────────────────────────── -->
    <CostBreakdown
      byModel={costByModel.map(m => ({ model: m.model, cost_cents: m.cost_cents, count: m.count }))}
      byAgent={costByAgent.map(a => ({ agent_name: a.agent_name, cost_cents: a.cost_cents, count: a.count }))}
      loading={budgetLoading}
    />

    <!-- ── Budget controls ─────────────────────────────────────────────── -->
    <BudgetControls
      agents={agentBudgets}
      onUpdate={(name, daily, monthly) => usageStore.updateBudget(name, daily, monthly)}
      onReset={(name) => usageStore.resetBudget(name)}
      loading={budgetLoading}
    />

  </main>
</div>

<style>
  /* ── Page layout ────────────────────────────────────────────────────────── */
  .page-container {
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
    gap: 16px;
    padding: 20px 24px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
  }

  .page-content {
    flex: 1;
    overflow-y: auto;
    padding: 20px 24px 24px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  /* ── Header left ────────────────────────────────────────────────────────── */
  .ua-header-left {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .ua-title {
    font-size: 20px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.02em;
  }

  .ua-subtitle {
    font-size: 13px;
    color: var(--text-tertiary);
  }

  /* ── Period selector (glassmorphic segmented control) ───────────────────── */
  .ua-period-selector {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 3px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-md);
    flex-shrink: 0;
  }

  .ua-period-btn {
    padding: 5px 14px;
    font-size: 12px;
    font-weight: 500;
    color: var(--text-tertiary);
    background: transparent;
    border: 1px solid transparent;
    border-radius: calc(var(--radius-md) - 3px);
    cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease, border-color 0.15s ease;
    white-space: nowrap;
  }

  .ua-period-btn:hover:not(.ua-period-btn--active) {
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.05);
  }

  .ua-period-btn--active {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.15);
    color: var(--text-primary);
    font-weight: 600;
  }

  .ua-period-btn:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: 2px;
  }

  /* ── Error state ────────────────────────────────────────────────────────── */
  .ua-error {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 14px 16px;
    color: var(--text-secondary);
  }

  .ua-error svg {
    color: var(--accent-error);
    flex-shrink: 0;
  }

  .ua-error-body {
    flex: 1;
    min-width: 0;
  }

  .ua-error-title {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
  }

  .ua-error-msg {
    font-size: 12px;
    color: var(--text-tertiary);
    margin-top: 2px;
  }

  .ua-retry-btn {
    padding: 5px 14px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    font-size: 12px;
    font-weight: 500;
    color: var(--text-primary);
    cursor: pointer;
    transition: background 0.15s ease;
    flex-shrink: 0;
  }

  .ua-retry-btn:hover {
    background: rgba(255, 255, 255, 0.12);
  }

  .ua-retry-btn:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: 2px;
  }

  /* ── Stat grid ──────────────────────────────────────────────────────────── */
  .ua-stat-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 12px;
  }

  @media (max-width: 900px) {
    .ua-stat-grid {
      grid-template-columns: repeat(2, 1fr);
    }
  }

  @media (max-width: 560px) {
    .ua-stat-grid {
      grid-template-columns: 1fr;
    }
  }

  /* ── Charts section ─────────────────────────────────────────────────────── */
  .ua-charts {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
  }

  @media (max-width: 720px) {
    .ua-charts {
      grid-template-columns: 1fr;
    }
  }

  .ua-chart-card {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .ua-chart-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }

  .ua-chart-title {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
  }

  .ua-chart-period {
    font-size: 11px;
    color: var(--text-tertiary);
  }

  .ua-chart-body {
    flex: 1;
    min-height: 0;
  }

  /* ── Model breakdown ────────────────────────────────────────────────────── */
  .ua-models {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  .ua-section-header {
    display: flex;
    align-items: baseline;
    gap: 8px;
  }

  .ua-section-title {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
  }

  .ua-section-sub {
    font-size: 11px;
    color: var(--text-tertiary);
  }

  .ua-model-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
    list-style: none;
  }

  .ua-model-row {
    display: grid;
    grid-template-columns: 200px 1fr 60px;
    align-items: center;
    gap: 12px;
  }

  @media (max-width: 640px) {
    .ua-model-row {
      grid-template-columns: 140px 1fr 48px;
    }
  }

  .ua-model-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .ua-model-name {
    font-size: 12px;
    font-weight: 500;
    color: var(--text-primary);
    font-family: var(--font-mono);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .ua-model-msgs {
    font-size: 10px;
    color: var(--text-tertiary);
  }

  .ua-model-bar-wrap {
    height: 8px;
    background: rgba(255, 255, 255, 0.04);
    border-radius: var(--radius-full);
    overflow: hidden;
  }

  .ua-model-bar {
    height: 100%;
    border-radius: var(--radius-full);
    border: 1px solid transparent;
    transition: width 0.3s ease;
  }

  .ua-model-tokens {
    font-size: 12px;
    font-weight: 500;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
    text-align: right;
  }

  /* ── Model skeletons ────────────────────────────────────────────────────── */
  .ua-model-sk-name,
  .ua-model-sk-bar,
  .ua-model-sk-stat {
    border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.06);
    animation: ua-shimmer 1.4s ease-in-out infinite;
  }

  .ua-model-sk-name {
    height: 12px;
    width: 140px;
  }

  .ua-model-sk-bar {
    height: 8px;
    width: 100%;
    border-radius: var(--radius-full);
    animation-delay: 0.1s;
  }

  .ua-model-sk-stat {
    height: 12px;
    width: 40px;
    margin-left: auto;
    animation-delay: 0.2s;
  }

  /* ── Empty ──────────────────────────────────────────────────────────────── */
  .ua-models-empty {
    padding: 24px 0;
    text-align: center;
    font-size: 13px;
    color: var(--text-tertiary);
  }

  /* ── Keyframes ──────────────────────────────────────────────────────────── */
  @keyframes ua-shimmer {
    0%, 100% { opacity: 0.5; }
    50%       { opacity: 1; }
  }

  @media (prefers-reduced-motion: reduce) {
    .ua-model-sk-name,
    .ua-model-sk-bar,
    .ua-model-sk-stat {
      animation: none;
    }
    .ua-model-bar {
      transition: none;
    }
  }
</style>
