<script lang="ts">
  import type {
    DashboardAdaptation,
    DashboardAdaptationSignal,
  } from "$api/types";

  interface Props {
    adaptation: DashboardAdaptation;
  }

  let { adaptation }: Props = $props();

  const journalTone = $derived(statusTone(adaptation.journal.status));
  const trialTone = $derived(statusTone(adaptation.current_trial?.status));

  function statusTone(status?: string | null): string {
    if (
      status === "running" ||
      status === "pending" ||
      status === "awaiting_outcome"
    ) {
      return "adp-status--ok";
    }

    if (status === "inactive" || status === "expired") {
      return "adp-status--warn";
    }

    if (status === "blocked" || status === "failed") {
      return "adp-status--error";
    }

    return "adp-status--muted";
  }

  function labelize(value?: string | null): string {
    if (!value) return "none";
    return value.replaceAll("_", " ");
  }

  function relativeTime(ts?: string | null): string {
    if (!ts) return "now";

    const diff = Math.floor((Date.now() - new Date(ts).getTime()) / 1000);
    if (diff < 60) return `${Math.max(diff, 0)}s ago`;
    if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
    return `${Math.floor(diff / 86400)}d ago`;
  }

  function signalDetail(signal: DashboardAdaptationSignal): string {
    const parts = [
      signal.domain ? labelize(signal.domain) : null,
      signal.bottleneck ? labelize(signal.bottleneck) : null,
      signal.reason ?? signal.outcome ?? signal.trigger_event,
    ].filter(Boolean);

    return parts.join(" • ");
  }
</script>

<section class="adp" aria-label="Adaptation state">
  <header class="adp-header">
    <div>
      <h3 class="adp-title">Adaptation State</h3>
      <p class="adp-subtitle">Read-only journal and trial visibility</p>
    </div>
    <span class={`adp-status ${journalTone}`}
      >{labelize(adaptation.journal.status)}</span
    >
  </header>

  <div class="adp-metrics">
    <div class="adp-metric">
      <span class="adp-metric-label">Authority</span>
      <strong class="adp-metric-value"
        >{labelize(adaptation.meta_state.authority_domain)}</strong
      >
    </div>
    <div class="adp-metric">
      <span class="adp-metric-label">Bottleneck</span>
      <strong class="adp-metric-value"
        >{labelize(adaptation.meta_state.active_bottleneck)}</strong
      >
    </div>
    <div class="adp-metric">
      <span class="adp-metric-label">Signals</span>
      <strong class="adp-metric-value">{adaptation.journal.signal_count}</strong
      >
    </div>
    <div class="adp-metric">
      <span class="adp-metric-label">Failed</span>
      <strong class="adp-metric-value"
        >{adaptation.meta_state.recent_failed_count}</strong
      >
    </div>
  </div>

  <div class="adp-section">
    <div class="adp-section-head">
      <span class="adp-section-title">Steering</span>
      {#if adaptation.meta_state.last_updated_at}
        <span class="adp-section-meta"
          >{relativeTime(adaptation.meta_state.last_updated_at)}</span
        >
      {/if}
    </div>
    <p class="adp-copy">
      {#if adaptation.meta_state.active_steering_hypothesis}
        {adaptation.meta_state.active_steering_hypothesis}
      {:else if adaptation.meta_state.pivot_reason}
        Pivot reason: {labelize(adaptation.meta_state.pivot_reason)}
      {:else}
        No active steering hypothesis.
      {/if}
    </p>
  </div>

  <div class="adp-section">
    <div class="adp-section-head">
      <span class="adp-section-title">Current Trial</span>
      {#if adaptation.current_trial}
        <span class={`adp-status ${trialTone}`}
          >{labelize(adaptation.current_trial.status)}</span
        >
      {/if}
    </div>

    {#if adaptation.current_trial}
      <div class="adp-trial">
        <div class="adp-trial-row">
          <span>{labelize(adaptation.current_trial.trigger_event)}</span>
          <span>{adaptation.current_trial.remaining_uses} use left</span>
        </div>
        <div class="adp-trial-row adp-trial-row--muted">
          <span>{labelize(adaptation.current_trial.bottleneck)}</span>
          {#if adaptation.current_trial.expires_at}
            <span
              >expires {relativeTime(adaptation.current_trial.expires_at)}</span
            >
          {/if}
        </div>
        {#if adaptation.current_trial.steering}
          <p class="adp-copy">{adaptation.current_trial.steering}</p>
        {/if}
      </div>
    {:else}
      <p class="adp-empty">No active trial.</p>
    {/if}
  </div>

  <div class="adp-flags">
    <div class="adp-flag-card">
      <span class="adp-flag-label">Promotions</span>
      {#if adaptation.active_promotions.length > 0}
        <span class="adp-flag-value">
          {labelize(adaptation.active_promotions[0].trigger_event)} ({adaptation
            .active_promotions[0].helpful_streak})
        </span>
      {:else}
        <span class="adp-flag-value adp-flag-value--muted">none</span>
      {/if}
    </div>
    <div class="adp-flag-card">
      <span class="adp-flag-label">Suppressions</span>
      {#if adaptation.active_suppressions.length > 0}
        <span class="adp-flag-value">
          {labelize(adaptation.active_suppressions[0].trigger_event)} ({adaptation
            .active_suppressions[0].negative_streak})
        </span>
      {:else}
        <span class="adp-flag-value adp-flag-value--muted">none</span>
      {/if}
    </div>
    <div class="adp-flag-card">
      <span class="adp-flag-label">In Flight</span>
      <span class="adp-flag-value">{adaptation.journal.in_flight_count}</span>
    </div>
  </div>

  <div class="adp-section">
    <div class="adp-section-head">
      <span class="adp-section-title">Recent Signals</span>
      <span class="adp-section-meta">{adaptation.recent_signals.length}</span>
    </div>

    {#if adaptation.recent_signals.length === 0}
      <p class="adp-empty">No recent adaptation signals.</p>
    {:else}
      <ul class="adp-list">
        {#each adaptation.recent_signals.slice(0, 4) as signal, index (signal.timestamp ?? `${signal.event_type}-${index}`)}
          <li class="adp-item">
            <div class="adp-item-row">
              <strong class="adp-item-title"
                >{labelize(signal.event_type)}</strong
              >
              <span class="adp-item-time">{relativeTime(signal.timestamp)}</span
              >
            </div>
            {#if signalDetail(signal)}
              <p class="adp-item-copy">{signalDetail(signal)}</p>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  </div>
</section>

<style>
  .adp {
    background: var(--bg-surface);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  .adp-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
  }

  .adp-title {
    margin: 0;
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
  }

  .adp-subtitle {
    margin: 4px 0 0;
    font-size: 11px;
    color: var(--text-tertiary);
  }

  .adp-status {
    border-radius: var(--radius-full);
    padding: 3px 8px;
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    border: 1px solid transparent;
    white-space: nowrap;
  }

  .adp-status--ok {
    color: var(--accent-success);
    background: rgba(34, 197, 94, 0.12);
    border-color: rgba(34, 197, 94, 0.2);
  }

  .adp-status--warn {
    color: var(--accent-warning);
    background: rgba(245, 158, 11, 0.12);
    border-color: rgba(245, 158, 11, 0.2);
  }

  .adp-status--error {
    color: var(--accent-error);
    background: rgba(239, 68, 68, 0.12);
    border-color: rgba(239, 68, 68, 0.2);
  }

  .adp-status--muted {
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.04);
    border-color: var(--border-default);
  }

  .adp-metrics {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
  }

  .adp-metric,
  .adp-flag-card {
    border: 1px solid var(--border-default);
    border-radius: var(--radius-sm);
    padding: 10px;
    background: rgba(255, 255, 255, 0.02);
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .adp-metric-label,
  .adp-flag-label,
  .adp-section-meta {
    font-size: 11px;
    color: var(--text-tertiary);
  }

  .adp-metric-value,
  .adp-flag-value,
  .adp-section-title,
  .adp-item-title {
    color: var(--text-primary);
    font-size: 12px;
  }

  .adp-flag-value--muted {
    color: var(--text-tertiary);
  }

  .adp-section {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .adp-section-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }

  .adp-copy,
  .adp-item-copy,
  .adp-empty {
    margin: 0;
    font-size: 12px;
    line-height: 1.45;
    color: var(--text-tertiary);
  }

  .adp-trial {
    border: 1px solid var(--border-default);
    border-radius: var(--radius-sm);
    padding: 10px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    background:
      linear-gradient(
        180deg,
        rgba(59, 130, 246, 0.08),
        rgba(59, 130, 246, 0.01)
      ),
      rgba(255, 255, 255, 0.02);
  }

  .adp-trial-row,
  .adp-item-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    font-size: 12px;
    color: var(--text-primary);
  }

  .adp-trial-row--muted,
  .adp-item-time {
    color: var(--text-tertiary);
  }

  .adp-flags {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 8px;
  }

  .adp-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .adp-item {
    border-top: 1px solid var(--border-default);
    padding-top: 8px;
  }

  .adp-item:first-child {
    border-top: 0;
    padding-top: 0;
  }

  @media (max-width: 768px) {
    .adp-metrics,
    .adp-flags {
      grid-template-columns: 1fr;
    }
  }
</style>
