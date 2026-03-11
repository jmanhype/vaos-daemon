<!-- src/lib/components/usage/UsageChart.svelte -->
<!-- Pure CSS bar chart (no chart library). Vertical bars with hover tooltips. -->
<script lang="ts">
  import type { DailyUsage } from "$lib/stores/usage.svelte";

  interface Props {
    data: DailyUsage[];
    metric: "messages" | "tokens";
    height?: number;
  }

  let { data, metric, height = 200 }: Props = $props();

  // ── Derived ────────────────────────────────────────────────────────────────

  let maxValue = $derived(
    data.length === 0
      ? 0
      : Math.max(...data.map((d) => d[metric]), 1),
  );

  let midValue = $derived(Math.round(maxValue / 2));

  /** Index of the currently hovered bar, or -1 */
  let hoveredIndex = $state(-1);

  // ── Helpers ────────────────────────────────────────────────────────────────

  function barHeight(val: number): number {
    if (maxValue === 0) return 0;
    return Math.max((val / maxValue) * 100, val > 0 ? 2 : 0);
  }

  function formatLabel(date: string): string {
    // "YYYY-MM-DD" → "Jan 5"
    const d = new Date(date + "T00:00:00");
    return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
  }

  function formatValue(val: number): string {
    if (metric === "tokens") {
      if (val >= 1_000_000) return `${(val / 1_000_000).toFixed(1)}M`;
      if (val >= 1_000) return `${Math.round(val / 1_000)}K`;
      return String(val);
    }
    return String(val);
  }

  function showXLabel(i: number): boolean {
    // Show label every 5th bar, and always the last bar
    return i % 5 === 0 || i === data.length - 1;
  }
</script>

<div class="uc-root" style="--chart-height: {height}px" aria-label="Usage chart">
  {#if data.length === 0}
    <!-- Empty state -->
    <div class="uc-empty">
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
        <path d="M3 3v18h18" />
        <path d="M7 16l4-4 4 4 5-5" />
      </svg>
      <p>No data for this period</p>
    </div>
  {:else}
    <!-- Y-axis labels -->
    <div class="uc-y-axis" aria-hidden="true">
      <span class="uc-y-label">{formatValue(maxValue)}</span>
      <span class="uc-y-label">{formatValue(midValue)}</span>
      <span class="uc-y-label">0</span>
    </div>

    <!-- Chart area -->
    <div class="uc-chart-area">
      <!-- Y-axis grid lines -->
      <div class="uc-grid-lines" aria-hidden="true">
        <div class="uc-grid-line"></div>
        <div class="uc-grid-line"></div>
        <div class="uc-grid-line"></div>
      </div>

      <!-- Bars -->
      <div class="uc-bars" role="img" aria-label="Bar chart of {metric} over time">
        {#each data as entry, i (entry.date)}
          {@const val = entry[metric]}
          {@const pct = barHeight(val)}
          {@const isHovered = hoveredIndex === i}

          <div
            class="uc-bar-col"
            onmouseenter={() => (hoveredIndex = i)}
            onmouseleave={() => (hoveredIndex = -1)}
            role="listitem"
            aria-label="{formatLabel(entry.date)}: {formatValue(val)} {metric}"
          >
            <!-- Tooltip -->
            {#if isHovered}
              <div class="uc-tooltip" role="tooltip">
                <span class="uc-tooltip-date">{formatLabel(entry.date)}</span>
                <span class="uc-tooltip-val">{formatValue(val)} {metric}</span>
              </div>
            {/if}

            <!-- Bar fill -->
            <div
              class="uc-bar"
              class:uc-bar--hovered={isHovered}
              class:uc-bar--zero={val === 0}
              style="height: {pct}%"
            ></div>

            <!-- X-axis label -->
            {#if showXLabel(i)}
              <span class="uc-x-label" aria-hidden="true">{formatLabel(entry.date)}</span>
            {/if}
          </div>
        {/each}
      </div>
    </div>
  {/if}
</div>

<style>
  /* ── Root ───────────────────────────────────────────────────────────────── */
  .uc-root {
    position: relative;
    display: flex;
    gap: 8px;
    width: 100%;
    height: var(--chart-height, 200px);
    padding-bottom: 20px; /* space for x-axis labels */
    box-sizing: content-box;
  }

  /* ── Empty state ────────────────────────────────────────────────────────── */
  .uc-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    width: 100%;
    color: var(--text-tertiary);
    font-size: 13px;
  }

  /* ── Y-axis ─────────────────────────────────────────────────────────────── */
  .uc-y-axis {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    align-items: flex-end;
    padding-bottom: 0;
    flex-shrink: 0;
    width: 36px;
    height: 100%;
  }

  .uc-y-label {
    font-size: 10px;
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
    line-height: 1;
  }

  /* ── Chart area ─────────────────────────────────────────────────────────── */
  .uc-chart-area {
    position: relative;
    flex: 1;
    min-width: 0;
    height: 100%;
  }

  /* ── Grid lines ─────────────────────────────────────────────────────────── */
  .uc-grid-lines {
    position: absolute;
    inset: 0 0 0 0;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    pointer-events: none;
  }

  .uc-grid-line {
    width: 100%;
    height: 1px;
    background: rgba(255, 255, 255, 0.05);
  }

  /* ── Bars container ─────────────────────────────────────────────────────── */
  .uc-bars {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: flex-end;
    gap: 2px;
    padding: 0 2px;
  }

  /* ── Individual bar column ──────────────────────────────────────────────── */
  .uc-bar-col {
    position: relative;
    flex: 1;
    min-width: 0;
    height: 100%;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: flex-end;
    cursor: default;
  }

  /* ── Bar fill ───────────────────────────────────────────────────────────── */
  .uc-bar {
    width: 100%;
    min-height: 0;
    border-radius: 3px 3px 0 0;
    background: linear-gradient(
      to top,
      rgba(59, 130, 246, 0.3),
      rgba(59, 130, 246, 0.7)
    );
    transition: background 0.15s ease, height 0.2s ease;
    flex-shrink: 0;
  }

  .uc-bar--hovered {
    background: linear-gradient(
      to top,
      rgba(59, 130, 246, 0.5),
      rgba(99, 160, 255, 0.9)
    );
  }

  .uc-bar--zero {
    background: rgba(255, 255, 255, 0.04);
  }

  /* ── X-axis label ───────────────────────────────────────────────────────── */
  .uc-x-label {
    position: absolute;
    bottom: -18px;
    font-size: 9px;
    color: var(--text-tertiary);
    white-space: nowrap;
    text-align: center;
    left: 50%;
    transform: translateX(-50%);
    pointer-events: none;
  }

  /* ── Tooltip ────────────────────────────────────────────────────────────── */
  .uc-tooltip {
    position: absolute;
    bottom: calc(100% + 6px);
    left: 50%;
    transform: translateX(-50%);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 2px;
    padding: 6px 10px;
    background: rgba(20, 20, 20, 0.95);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-sm);
    white-space: nowrap;
    pointer-events: none;
    z-index: 10;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.4);
  }

  .uc-tooltip-date {
    font-size: 10px;
    color: var(--text-secondary);
  }

  .uc-tooltip-val {
    font-size: 12px;
    font-weight: 600;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
  }
</style>
