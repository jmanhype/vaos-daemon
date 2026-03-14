<script lang="ts">
  interface ModelEntry { model: string; cost_cents: number; count: number; }
  interface AgentEntry { agent_name: string; cost_cents: number; count: number; }

  interface Props {
    byModel: ModelEntry[];
    byAgent: AgentEntry[];
    loading?: boolean;
  }

  let { byModel, byAgent, loading = false }: Props = $props();

  function fmt(cents: number): string {
    return `$${(cents / 100).toFixed(2)}`;
  }

  function barPct(value: number, max: number): number {
    if (max === 0) return 0;
    return Math.max((value / max) * 100, value > 0 ? 2 : 0);
  }

  const palette = [
    "rgba(59, 130, 246, 0.6)", "rgba(168, 85, 247, 0.6)",
    "rgba(34, 197, 94, 0.6)", "rgba(245, 158, 11, 0.6)", "rgba(236, 72, 153, 0.6)",
  ];

  let maxModel = $derived(byModel.length === 0 ? 1 : Math.max(...byModel.map(m => m.cost_cents), 1));
  let maxAgent = $derived(byAgent.length === 0 ? 1 : Math.max(...byAgent.map(a => a.cost_cents), 1));
</script>

<section class="cb-root" aria-label="Cost breakdown">
  <div class="cb-col glass-panel">
    <header class="cb-header">
      <h2 class="cb-title">Cost by Model</h2>
    </header>
    {#if loading}
      {#each [1, 2, 3] as _}
        <div class="cb-row"><div class="cb-sk"></div><div class="cb-sk cb-sk--bar"></div><div class="cb-sk cb-sk--num"></div></div>
      {/each}
    {:else if byModel.length === 0}
      <p class="cb-empty">No cost data</p>
    {:else}
      <ol class="cb-list">
        {#each byModel as m, i (m.model)}
          <li class="cb-row">
            <span class="cb-name">{m.model}</span>
            <div class="cb-bar-wrap" aria-hidden="true">
              <div class="cb-bar" style="width: {barPct(m.cost_cents, maxModel)}%; background: {palette[i % palette.length]}"></div>
            </div>
            <span class="cb-val">{fmt(m.cost_cents)}</span>
          </li>
        {/each}
      </ol>
    {/if}
  </div>

  <div class="cb-col glass-panel">
    <header class="cb-header">
      <h2 class="cb-title">Cost by Agent</h2>
    </header>
    {#if loading}
      {#each [1, 2, 3] as _}
        <div class="cb-row"><div class="cb-sk"></div><div class="cb-sk cb-sk--bar"></div><div class="cb-sk cb-sk--num"></div></div>
      {/each}
    {:else if byAgent.length === 0}
      <p class="cb-empty">No cost data</p>
    {:else}
      <ol class="cb-list">
        {#each byAgent as a, i (a.agent_name)}
          <li class="cb-row">
            <span class="cb-name">{a.agent_name}</span>
            <div class="cb-bar-wrap" aria-hidden="true">
              <div class="cb-bar" style="width: {barPct(a.cost_cents, maxAgent)}%; background: {palette[i % palette.length]}"></div>
            </div>
            <span class="cb-val">{fmt(a.cost_cents)}</span>
          </li>
        {/each}
      </ol>
    {/if}
  </div>
</section>

<style>
  .cb-root { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  @media (max-width: 720px) { .cb-root { grid-template-columns: 1fr; } }
  .cb-col { padding: 16px; display: flex; flex-direction: column; gap: 10px; }
  .cb-header { display: flex; align-items: baseline; }
  .cb-title { font-size: 13px; font-weight: 600; color: var(--text-primary); }
  .cb-list { display: flex; flex-direction: column; gap: 8px; list-style: none; }
  .cb-row { display: grid; grid-template-columns: 120px 1fr 52px; align-items: center; gap: 10px; }
  .cb-name { font-size: 11px; font-family: var(--font-mono); color: var(--text-secondary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .cb-bar-wrap { height: 6px; background: rgba(255, 255, 255, 0.04); border-radius: var(--radius-full); overflow: hidden; }
  .cb-bar { height: 100%; border-radius: var(--radius-full); transition: width 0.3s ease; }
  .cb-val { font-size: 11px; font-weight: 500; color: var(--text-secondary); text-align: right; font-variant-numeric: tabular-nums; }
  .cb-empty { font-size: 12px; color: var(--text-tertiary); text-align: center; padding: 16px 0; }
  .cb-sk { height: 10px; width: 80px; border-radius: var(--radius-sm); background: rgba(255, 255, 255, 0.06); animation: cb-shimmer 1.4s ease-in-out infinite; }
  .cb-sk--bar { width: 100%; height: 6px; border-radius: var(--radius-full); }
  .cb-sk--num { width: 40px; margin-left: auto; }
  @keyframes cb-shimmer { 0%, 100% { opacity: 0.5; } 50% { opacity: 1; } }
  @media (prefers-reduced-motion: reduce) { .cb-bar { transition: none; } .cb-sk { animation: none; } }
</style>
