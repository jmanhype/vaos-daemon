<script lang="ts">
  import { slide } from "svelte/transition";
  import type { Signal } from "$lib/api/types";

  interface Props {
    signal: Signal;
  }

  let { signal }: Props = $props();

  let expanded = $state(false);

  function tierClass(tier: string): string {
    return `tier-${tier}`;
  }

  function relativeTime(iso: string): string {
    const diff = Date.now() - new Date(iso).getTime();
    const secs = Math.floor(diff / 1000);
    if (secs < 60) return `${secs}s ago`;
    const mins = Math.floor(secs / 60);
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    return `${Math.floor(hrs / 24)}d ago`;
  }
</script>

<button
  class="signal-card"
  onclick={() => { expanded = !expanded; }}
  aria-expanded={expanded}
>
  <div class="card-main">
    <span class="weight-badge {tierClass(signal.tier)}">{signal.weight.toFixed(2)}</span>

    <div class="card-body">
      <p class="card-preview">{signal.input_preview}</p>
      <div class="card-meta">
        <span class="mode-tag">{signal.mode}</span>
        <span class="meta-sep">&middot;</span>
        <span class="meta-text">{signal.channel}</span>
        <span class="meta-sep">&middot;</span>
        <span class="meta-text">{signal.agent_name}</span>
      </div>
    </div>

    <span class="card-time">{relativeTime(signal.inserted_at)}</span>
  </div>

  {#if expanded}
    <div class="card-details" transition:slide={{ duration: 160 }}>
      <div class="detail-row">
        <span class="detail-label">Genre</span>
        <span class="detail-value">{signal.genre}</span>
      </div>
      <div class="detail-row">
        <span class="detail-label">Type</span>
        <span class="detail-value">{signal.type}</span>
      </div>
      <div class="detail-row">
        <span class="detail-label">Format</span>
        <span class="detail-value">{signal.format}</span>
      </div>
      <div class="detail-row">
        <span class="detail-label">Confidence</span>
        <span class="detail-value">{signal.confidence}</span>
      </div>
      {#if Object.keys(signal.metadata).length > 0}
        <pre class="detail-json">{JSON.stringify(signal.metadata, null, 2)}</pre>
      {/if}
    </div>
  {/if}
</button>

<style>
  .signal-card {
    display: flex;
    flex-direction: column;
    width: 100%;
    text-align: left;
    padding: 10px 12px;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid transparent;
    border-radius: var(--radius-sm);
    transition: background var(--transition-fast), border-color var(--transition-fast);
  }

  .signal-card:hover {
    background: var(--bg-elevated);
    border-color: var(--border-default);
  }

  .card-main {
    display: flex;
    align-items: flex-start;
    gap: 10px;
  }

  .weight-badge {
    flex-shrink: 0;
    width: 42px;
    padding: 2px 0;
    text-align: center;
    font-size: 0.7rem;
    font-weight: 600;
    font-family: var(--font-mono);
    border-radius: var(--radius-xs);
  }

  .tier-haiku {
    background: rgba(34, 197, 94, 0.15);
    color: #4ade80;
    border: 1px solid rgba(34, 197, 94, 0.25);
  }

  .tier-sonnet {
    background: rgba(245, 158, 11, 0.15);
    color: #fbbf24;
    border: 1px solid rgba(245, 158, 11, 0.25);
  }

  .tier-opus {
    background: rgba(239, 68, 68, 0.15);
    color: #f87171;
    border: 1px solid rgba(239, 68, 68, 0.25);
  }

  .card-body {
    flex: 1;
    min-width: 0;
  }

  .card-preview {
    font-size: 0.8rem;
    color: var(--text-primary);
    line-height: 1.4;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .card-meta {
    display: flex;
    align-items: center;
    gap: 4px;
    margin-top: 4px;
  }

  .mode-tag {
    font-size: 0.6rem;
    font-weight: 600;
    letter-spacing: 0.04em;
    padding: 1px 6px;
    border-radius: var(--radius-xs);
    background: rgba(59, 130, 246, 0.1);
    color: rgba(96, 165, 250, 0.9);
  }

  .meta-sep {
    color: var(--text-muted);
    font-size: 0.6rem;
  }

  .meta-text {
    font-size: 0.65rem;
    color: var(--text-tertiary);
  }

  .card-time {
    flex-shrink: 0;
    font-size: 0.6rem;
    font-family: var(--font-mono);
    color: var(--text-muted);
    padding-top: 2px;
  }

  .card-details {
    margin-top: 8px;
    padding-top: 8px;
    border-top: 1px solid var(--border-default);
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .detail-row {
    display: flex;
    justify-content: space-between;
    font-size: 0.65rem;
  }

  .detail-label {
    color: var(--text-tertiary);
  }

  .detail-value {
    color: var(--text-secondary);
    font-family: var(--font-mono);
  }

  .detail-json {
    margin-top: 4px;
    padding: 8px;
    background: rgba(255, 255, 255, 0.03);
    border-radius: var(--radius-xs);
    font-size: 0.6rem;
    font-family: var(--font-mono);
    color: var(--text-tertiary);
    overflow-x: auto;
    white-space: pre-wrap;
    word-break: break-all;
  }
</style>
