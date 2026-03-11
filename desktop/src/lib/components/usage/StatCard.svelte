<!-- src/lib/components/usage/StatCard.svelte -->
<!-- Glassmorphic stat card with optional trend indicator and skeleton state. -->
<script lang="ts">
  interface Props {
    label: string;
    value: string | number;
    subtitle?: string;
    trend?: "up" | "down" | "neutral";
    trendValue?: string;
    icon?: string;
    loading?: boolean;
  }

  let {
    label,
    value,
    subtitle,
    trend,
    trendValue,
    icon,
    loading = false,
  }: Props = $props();

  const trendColor = $derived(
    trend === "up"
      ? "sc-trend--up"
      : trend === "down"
        ? "sc-trend--down"
        : "sc-trend--neutral",
  );
</script>

<article class="sc-card" aria-label="{label}: {loading ? 'loading' : value}">
  {#if loading}
    <!-- Skeleton state -->
    <div class="sc-skeleton-icon"></div>
    <div class="sc-skeleton-label"></div>
    <div class="sc-skeleton-value"></div>
    {#if subtitle}
      <div class="sc-skeleton-sub"></div>
    {/if}
  {:else}
    <!-- Icon -->
    {#if icon}
      <div class="sc-icon-wrap" aria-hidden="true">
        <svg
          width="18"
          height="18"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.75"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d={icon} />
        </svg>
      </div>
    {/if}

    <!-- Label -->
    <p class="sc-label">{label}</p>

    <!-- Value + trend -->
    <div class="sc-value-row">
      <span class="sc-value">{value}</span>
      {#if trend && trendValue}
        <span class="sc-trend {trendColor}" aria-label="Trend: {trendValue}">
          {#if trend === "up"}
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" aria-hidden="true">
              <polyline points="18 15 12 9 6 15" />
            </svg>
          {:else if trend === "down"}
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" aria-hidden="true">
              <polyline points="6 9 12 15 18 9" />
            </svg>
          {/if}
          {trendValue}
        </span>
      {/if}
    </div>

    <!-- Subtitle -->
    {#if subtitle}
      <p class="sc-subtitle">{subtitle}</p>
    {/if}
  {/if}
</article>

<style>
  /* ── Card shell ─────────────────────────────────────────────────────────── */
  .sc-card {
    display: flex;
    flex-direction: column;
    gap: 6px;
    background: var(--bg-surface);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
    padding: 20px;
    min-width: 0;
    transition: border-color 0.15s ease, background 0.15s ease;
  }

  .sc-card:hover {
    border-color: var(--border-hover);
    background: var(--bg-elevated);
  }

  /* ── Icon ───────────────────────────────────────────────────────────────── */
  .sc-icon-wrap {
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(59, 130, 246, 0.1);
    border: 1px solid rgba(59, 130, 246, 0.2);
    border-radius: var(--radius-sm);
    color: var(--accent-primary);
    margin-bottom: 4px;
    flex-shrink: 0;
  }

  /* ── Label ──────────────────────────────────────────────────────────────── */
  .sc-label {
    font-size: 13px;
    font-weight: 500;
    color: var(--text-secondary);
    letter-spacing: 0.01em;
  }

  /* ── Value row ──────────────────────────────────────────────────────────── */
  .sc-value-row {
    display: flex;
    align-items: baseline;
    gap: 8px;
    flex-wrap: wrap;
  }

  .sc-value {
    font-size: 28px;
    font-weight: 700;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
    letter-spacing: -0.02em;
    line-height: 1;
  }

  /* ── Trend badge ────────────────────────────────────────────────────────── */
  .sc-trend {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    font-size: 11px;
    font-weight: 600;
    padding: 2px 6px;
    border-radius: var(--radius-full);
  }

  .sc-trend--up {
    color: #86efac;
    background: rgba(34, 197, 94, 0.1);
    border: 1px solid rgba(34, 197, 94, 0.2);
  }

  .sc-trend--down {
    color: #fca5a5;
    background: rgba(239, 68, 68, 0.08);
    border: 1px solid rgba(239, 68, 68, 0.18);
  }

  .sc-trend--neutral {
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
  }

  /* ── Subtitle ───────────────────────────────────────────────────────────── */
  .sc-subtitle {
    font-size: 12px;
    color: var(--text-tertiary);
    line-height: 1.4;
    margin-top: 2px;
  }

  /* ── Skeleton ───────────────────────────────────────────────────────────── */
  .sc-skeleton-icon,
  .sc-skeleton-label,
  .sc-skeleton-value,
  .sc-skeleton-sub {
    border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.06);
    animation: sc-shimmer 1.4s ease-in-out infinite;
  }

  .sc-skeleton-icon {
    width: 32px;
    height: 32px;
    border-radius: var(--radius-sm);
    margin-bottom: 4px;
  }

  .sc-skeleton-label {
    height: 13px;
    width: 80px;
  }

  .sc-skeleton-value {
    height: 28px;
    width: 120px;
    animation-delay: 0.1s;
  }

  .sc-skeleton-sub {
    height: 11px;
    width: 100px;
    animation-delay: 0.2s;
  }

  @keyframes sc-shimmer {
    0%, 100% { opacity: 0.5; }
    50%       { opacity: 1; }
  }

  @media (prefers-reduced-motion: reduce) {
    .sc-skeleton-icon,
    .sc-skeleton-label,
    .sc-skeleton-value,
    .sc-skeleton-sub {
      animation: none;
    }
  }
</style>
