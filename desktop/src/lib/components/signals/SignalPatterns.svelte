<script lang="ts">
  import type { SignalPatterns } from "$lib/api/types";

  interface Props {
    patterns: SignalPatterns | null;
  }

  let { patterns }: Props = $props();

  function formatHours(hours: number[]): string {
    if (hours.length === 0) return "—";
    const start = hours[0];
    const end = hours[hours.length - 1];
    return `${start % 12 || 12}${start < 12 ? 'am' : 'pm'}–${end % 12 || 12}${end < 12 ? 'am' : 'pm'}`;
  }
</script>

<div class="patterns-section">
  <span class="patterns-title">Patterns</span>
  <div class="patterns-grid">
    <div class="pattern-card">
      <span class="pattern-label">Peak Hours</span>
      <span class="pattern-value">{patterns ? formatHours(patterns.peak_hours) : '—'}</span>
    </div>
    <div class="pattern-card">
      <span class="pattern-label">Avg Weight</span>
      <span class="pattern-value">{patterns ? patterns.avg_weight.toFixed(2) : '—'}</span>
    </div>
    <div class="pattern-card">
      <span class="pattern-label">Top Agent</span>
      <span class="pattern-value">
        {patterns?.top_agents[0]
          ? `${patterns.top_agents[0].name} (${patterns.top_agents[0].count})`
          : '—'}
      </span>
    </div>
    <div class="pattern-card">
      <span class="pattern-label">Escalations</span>
      <span class="pattern-value">{patterns?.escalation_count ?? '—'}</span>
    </div>
  </div>
</div>

<style>
  .patterns-section {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .patterns-title {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .patterns-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 6px;
  }

  .pattern-card {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 10px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-sm);
  }

  .pattern-label {
    font-size: 0.6rem;
    color: var(--text-tertiary);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  .pattern-value {
    font-size: 0.8rem;
    font-weight: 600;
    font-family: var(--font-mono);
    color: var(--text-primary);
  }
</style>
