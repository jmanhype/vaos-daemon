<script lang="ts">
  interface AgentRow {
    agent_name: string;
    budget_daily_cents: number;
    budget_monthly_cents: number;
    status: string;
  }

  interface Props {
    agents: AgentRow[];
    onUpdate: (agentName: string, dailyCents: number, monthlyCents: number) => void;
    onReset: (agentName: string) => void;
    loading?: boolean;
  }

  let { agents, onUpdate, onReset, loading = false }: Props = $props();

  interface RowValues { daily: string; monthly: string; }
  let edits = $state<Record<string, RowValues>>({});
  let confirming = $state<string | null>(null);

  function getEdit(name: string, agent: AgentRow): RowValues {
    return edits[name] ?? {
      daily: (agent.budget_daily_cents / 100).toFixed(2),
      monthly: (agent.budget_monthly_cents / 100).toFixed(2),
    };
  }

  function setEdit(name: string, field: "daily" | "monthly", val: string) {
    const current = edits[name] ?? {
      daily: "",
      monthly: "",
    };
    edits = { ...edits, [name]: { ...current, [field]: val } };
  }

  function isDirty(name: string, agent: AgentRow): boolean {
    const edit = edits[name];
    if (!edit) return false;
    const origDaily = (agent.budget_daily_cents / 100).toFixed(2);
    const origMonthly = (agent.budget_monthly_cents / 100).toFixed(2);
    return edit.daily !== origDaily || edit.monthly !== origMonthly;
  }

  function save(name: string) {
    const edit = edits[name];
    if (!edit) return;
    const daily = Math.round(parseFloat(edit.daily) * 100);
    const monthly = Math.round(parseFloat(edit.monthly) * 100);
    if (daily > 0 && monthly > 0) {
      onUpdate(name, daily, monthly);
      delete edits[name];
      edits = { ...edits };
    }
  }

  function confirmReset(name: string) {
    confirming = name;
  }

  function doReset(name: string) {
    onReset(name);
    confirming = null;
  }
</script>

{#if agents.length > 0}
  <section class="bc-root glass-panel" aria-label="Budget controls">
    <header class="bc-header">
      <h2 class="bc-title">Budget Controls</h2>
      <span class="bc-sub">Per-agent limits</span>
    </header>

    <div class="bc-table" role="table" aria-label="Agent budget table">
      <div class="bc-thead" role="row">
        <span role="columnheader">Agent</span>
        <span role="columnheader">Daily ($)</span>
        <span role="columnheader">Monthly ($)</span>
        <span role="columnheader">Status</span>
        <span role="columnheader">Actions</span>
      </div>

      {#each agents as agent (agent.agent_name)}
        {@const edit = getEdit(agent.agent_name, agent)}
        {@const dirty = isDirty(agent.agent_name, agent)}
        <div class="bc-row" role="row">
          <span class="bc-agent-name" role="cell">{agent.agent_name}</span>
          <div role="cell">
            <input
              class="bc-input"
              type="number"
              min="0"
              step="0.01"
              value={edit.daily}
              oninput={(e) => setEdit(agent.agent_name, "daily", (e.target as HTMLInputElement).value)}
              disabled={loading}
              aria-label="Daily budget for {agent.agent_name}"
            />
          </div>
          <div role="cell">
            <input
              class="bc-input"
              type="number"
              min="0"
              step="0.01"
              value={edit.monthly}
              oninput={(e) => setEdit(agent.agent_name, "monthly", (e.target as HTMLInputElement).value)}
              disabled={loading}
              aria-label="Monthly budget for {agent.agent_name}"
            />
          </div>
          <span class="bc-status" role="cell" class:bc-status--paused={agent.status !== "active"}>
            {agent.status === "active" ? "Active" : "Paused"}
          </span>
          <div class="bc-actions" role="cell">
            {#if confirming === agent.agent_name}
              <span class="bc-confirm-text">Reset?</span>
              <button class="bc-btn bc-btn--yes" onclick={() => doReset(agent.agent_name)} disabled={loading}>Yes</button>
              <button class="bc-btn" onclick={() => confirming = null}>No</button>
            {:else}
              <button class="bc-btn bc-btn--save" onclick={() => save(agent.agent_name)} disabled={!dirty || loading}>Save</button>
              <button class="bc-btn" onclick={() => confirmReset(agent.agent_name)} disabled={loading}>Reset</button>
            {/if}
          </div>
        </div>
      {/each}
    </div>
  </section>
{/if}

<style>
  .bc-root { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
  .bc-header { display: flex; align-items: baseline; gap: 8px; }
  .bc-title { font-size: 13px; font-weight: 600; color: var(--text-primary); }
  .bc-sub { font-size: 11px; color: var(--text-tertiary); }
  .bc-table { display: flex; flex-direction: column; gap: 0; }
  .bc-thead { display: grid; grid-template-columns: 1fr 90px 90px 70px auto; gap: 8px; padding: 6px 0; border-bottom: 1px solid rgba(255, 255, 255, 0.08); font-size: 10px; font-weight: 600; color: var(--text-tertiary); text-transform: uppercase; letter-spacing: 0.05em; }
  .bc-row { display: grid; grid-template-columns: 1fr 90px 90px 70px auto; gap: 8px; align-items: center; padding: 8px 0; border-bottom: 1px solid rgba(255, 255, 255, 0.04); }
  .bc-agent-name { font-size: 12px; font-family: var(--font-mono); color: var(--text-secondary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .bc-input { width: 100%; padding: 4px 6px; font-size: 12px; font-variant-numeric: tabular-nums; background: rgba(255, 255, 255, 0.05); border: 1px solid rgba(255, 255, 255, 0.1); border-radius: var(--radius-sm); color: var(--text-primary); outline: none; }
  .bc-input:focus { border-color: var(--accent-primary); }
  .bc-input::-webkit-inner-spin-button, .bc-input::-webkit-outer-spin-button { -webkit-appearance: none; margin: 0; }
  .bc-status { font-size: 11px; color: var(--accent-success); }
  .bc-status--paused { color: var(--accent-warning); }
  .bc-actions { display: flex; gap: 4px; align-items: center; }
  .bc-btn { padding: 3px 8px; font-size: 11px; font-weight: 500; background: rgba(255, 255, 255, 0.06); border: 1px solid rgba(255, 255, 255, 0.1); border-radius: var(--radius-sm); color: var(--text-secondary); cursor: pointer; transition: background 0.15s; }
  .bc-btn:hover:not(:disabled) { background: rgba(255, 255, 255, 0.12); }
  .bc-btn:disabled { opacity: 0.4; cursor: default; }
  .bc-btn--save { color: var(--accent-primary); border-color: var(--accent-primary); }
  .bc-btn--yes { color: var(--accent-error); border-color: var(--accent-error); }
  .bc-confirm-text { font-size: 11px; color: var(--text-tertiary); }
  @media (max-width: 640px) { .bc-thead, .bc-row { grid-template-columns: 1fr 70px 70px 50px auto; } }
</style>
