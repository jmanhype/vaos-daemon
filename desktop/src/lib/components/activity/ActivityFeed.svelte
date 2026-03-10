<script lang="ts">
  import { slide } from 'svelte/transition';
  import { activityStore } from '$lib/stores/activity.svelte';
  import type { Activity } from '$lib/stores/activity.svelte';

  // ── Elapsed time formatting ──────────────────────────────────────────────────

  function formatMs(ms: number): string {
    if (ms < 1000) return `${ms}ms`;
    if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
    const m = Math.floor(ms / 60_000);
    const s = Math.floor((ms % 60_000) / 1000);
    return `${m}m ${s}s`;
  }

  function elapsedMs(activity: Activity): number {
    return (activity.finishedAt ?? Date.now()) - activity.startedAt;
  }

  // Tick every 250ms so elapsed times update during active calls
  let tick = $state(0);
  $effect(() => {
    const id = setInterval(() => { tick++; }, 250);
    return () => clearInterval(id);
  });

  // Reactive elapsed — reads tick to stay live
  function liveElapsed(a: Activity): string {
    void tick; // subscribe to tick
    return formatMs(elapsedMs(a));
  }

  // Total session elapsed
  const totalLabel = $derived(() => {
    void tick;
    return formatMs(activityStore.totalElapsedMs);
  });

  // Verbosity label
  const verbosityLabel: Record<string, string> = {
    off:     'Off',
    new:     'New',
    all:     'All',
    verbose: 'Verbose',
  };

  // ── Keyboard handler ─────────────────────────────────────────────────────────

  function onBarKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      activityStore.toggleExpanded();
    }
  }
</script>

{#if activityStore.activities.length > 0 && activityStore.verbosity !== 'off'}
  <div class="feed-wrap" role="region" aria-label="Activity feed">
    <!-- Collapsed bar — always visible when there are activities -->
    <div
      class="feed-bar"
      class:feed-bar--expanded={activityStore.isExpanded}
      onclick={activityStore.toggleExpanded.bind(activityStore)}
      onkeydown={onBarKeydown}
      role="button"
      tabindex="0"
      aria-expanded={activityStore.isExpanded}
      aria-controls="feed-list"
    >
      <!-- Current activity indicator -->
      {#if activityStore.currentActivity}
        {@const cur = activityStore.currentActivity}
        <span class="feed-emoji" aria-hidden="true">{cur.emoji}</span>
        <span class="feed-current-label">
          {cur.label || cur.tool}
        </span>
        <span
          class="feed-duration"
          class:feed-duration--running={cur.finishedAt === null}
          class:feed-duration--error={cur.isError}
        >
          {liveElapsed(cur)}
        </span>
      {:else}
        <span class="feed-current-label feed-idle">Idle</span>
      {/if}

      <div class="feed-bar-right">
        <!-- Activity count -->
        {#if activityStore.activities.length > 1}
          <span class="feed-count" aria-label="{activityStore.activities.length} tool calls">
            {activityStore.activities.length} calls
          </span>
        {/if}

        <!-- Total elapsed -->
        {#if activityStore.totalElapsedMs > 0}
          <span class="feed-total">
            {totalLabel()}
          </span>
        {/if}

        <!-- Verbosity toggle -->
        <button
          class="feed-verbosity"
          onclick={(e) => { e.stopPropagation(); activityStore.cycleVerbosity(); }}
          aria-label="Verbosity: {verbosityLabel[activityStore.verbosity]}. Click to cycle."
          title="Cycle verbosity"
        >
          {verbosityLabel[activityStore.verbosity]}
        </button>

        <!-- Chevron -->
        <span class="feed-chevron" class:rotated={activityStore.isExpanded} aria-hidden="true">›</span>
      </div>
    </div>

    <!-- Expanded list -->
    {#if activityStore.isExpanded}
      <div
        id="feed-list"
        class="feed-list"
        transition:slide={{ duration: 200 }}
        role="list"
        aria-label="Tool call history"
      >
        {#each activityStore.visibleActivities as activity (activity.id)}
          <div
            class="feed-item"
            class:feed-item--running={activity.finishedAt === null}
            class:feed-item--error={activity.isError}
            role="listitem"
          >
            <span class="feed-item-emoji" aria-hidden="true">{activity.emoji}</span>
            <span class="feed-item-label">{activity.label || activity.tool}</span>
            {#if activityStore.verbosity === 'verbose' && activity.summary}
              <span class="feed-item-summary">{activity.summary}</span>
            {/if}
            <span class="feed-item-duration" class:feed-item-duration--running={activity.finishedAt === null}>
              {liveElapsed(activity)}
            </span>
            {#if activity.isError}
              <span class="feed-item-error-dot" aria-label="Error" title="Tool returned error">!</span>
            {:else if activity.finishedAt !== null}
              <span class="feed-item-done-dot" aria-hidden="true">✓</span>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  </div>
{/if}

<style>
  /* ── Wrapper ── */

  .feed-wrap {
    width: 100%;
    overflow: hidden;
  }

  /* ── Collapsed bar ── */

  .feed-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 7px 12px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-md);
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
    font-size: 0.8125rem;
    user-select: none;
  }

  .feed-bar:hover {
    background: rgba(255, 255, 255, 0.06);
    border-color: rgba(255, 255, 255, 0.1);
  }

  .feed-bar--expanded {
    border-radius: 0 0 var(--radius-md) var(--radius-md);
    border-top-color: transparent;
    background: rgba(255, 255, 255, 0.05);
  }

  .feed-emoji {
    font-size: 0.875rem;
    flex-shrink: 0;
  }

  .feed-current-label {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.8125rem;
  }

  .feed-idle {
    color: rgba(255, 255, 255, 0.3);
    font-style: italic;
  }

  .feed-duration {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.35);
    flex-shrink: 0;
  }

  .feed-duration--running {
    color: rgba(255, 255, 255, 0.55);
    animation: pulse-opacity 1.5s ease-in-out infinite;
  }

  .feed-duration--error {
    color: rgba(239, 68, 68, 0.7);
  }

  @keyframes pulse-opacity {
    0%, 100% { opacity: 0.5; }
    50%       { opacity: 1; }
  }

  .feed-bar-right {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }

  .feed-count {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.25);
    font-family: var(--font-mono);
  }

  .feed-total {
    font-size: 0.6875rem;
    font-family: var(--font-mono);
    color: rgba(255, 255, 255, 0.3);
  }

  /* Verbosity toggle */
  .feed-verbosity {
    font-size: 0.625rem;
    font-weight: 500;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    padding: 2px 7px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.4);
    cursor: pointer;
    transition: background 0.12s, color 0.12s;
  }

  .feed-verbosity:hover {
    background: rgba(255, 255, 255, 0.12);
    color: rgba(255, 255, 255, 0.7);
  }

  .feed-chevron {
    font-size: 0.9375rem;
    color: rgba(255, 255, 255, 0.25);
    transition: transform 0.18s ease;
    display: inline-block;
  }

  .feed-chevron.rotated {
    transform: rotate(90deg);
  }

  /* ── Expanded list ── */

  .feed-list {
    background: rgba(0, 0, 0, 0.25);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-bottom-left-radius: var(--radius-md);
    border-bottom-right-radius: var(--radius-md);
    border-top: none;
    max-height: 260px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .feed-item {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    font-size: 0.8125rem;
    transition: background 0.1s;
  }

  .feed-item:last-child {
    border-bottom: none;
  }

  .feed-item:hover {
    background: rgba(255, 255, 255, 0.03);
  }

  .feed-item--running {
    background: rgba(255, 255, 255, 0.02);
  }

  .feed-item--error {
    background: rgba(239, 68, 68, 0.04);
  }

  .feed-item-emoji {
    font-size: 0.8125rem;
    flex-shrink: 0;
  }

  .feed-item-label {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: rgba(255, 255, 255, 0.65);
  }

  .feed-item-summary {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.3);
    max-width: 200px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex-shrink: 0;
  }

  .feed-item-duration {
    font-family: var(--font-mono);
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.25);
    flex-shrink: 0;
  }

  .feed-item-duration--running {
    color: rgba(255, 255, 255, 0.5);
    animation: pulse-opacity 1.5s ease-in-out infinite;
  }

  .feed-item-done-dot {
    font-size: 0.6875rem;
    color: rgba(34, 197, 94, 0.5);
    flex-shrink: 0;
  }

  .feed-item-error-dot {
    font-size: 0.75rem;
    font-weight: 700;
    color: rgba(239, 68, 68, 0.7);
    flex-shrink: 0;
  }
</style>
