<script lang="ts">
  import type { SignalFilters } from "$lib/api/types";

  interface Props {
    filters: SignalFilters;
    onFilter: (key: keyof SignalFilters, value: string | undefined) => void;
    onClear: () => void;
  }

  let { filters, onFilter, onClear }: Props = $props();

  const isFiltered = $derived(
    filters.mode !== undefined ||
    filters.type !== undefined ||
    filters.channel !== undefined,
  );

  const MODE_OPTIONS = [
    { value: '', label: 'All modes' },
    { value: 'BUILD', label: 'Build' },
    { value: 'EXECUTE', label: 'Execute' },
    { value: 'ANALYZE', label: 'Analyze' },
    { value: 'MAINTAIN', label: 'Maintain' },
    { value: 'ASSIST', label: 'Assist' },
  ];

  const TYPE_OPTIONS = [
    { value: '', label: 'All types' },
    { value: 'question', label: 'Question' },
    { value: 'request', label: 'Request' },
    { value: 'issue', label: 'Issue' },
    { value: 'scheduling', label: 'Scheduling' },
    { value: 'summary', label: 'Summary' },
    { value: 'report', label: 'Report' },
    { value: 'general', label: 'General' },
  ];

  const CHANNEL_OPTIONS = [
    { value: '', label: 'All channels' },
    { value: 'cli', label: 'CLI' },
    { value: 'http', label: 'HTTP' },
    { value: 'discord', label: 'Discord' },
    { value: 'telegram', label: 'Telegram' },
  ];
</script>

<div class="filters-bar" role="search" aria-label="Filter signals">
  <div class="select-wrapper">
    <select
      class="filter-select"
      value={filters.mode ?? ''}
      onchange={(e) => onFilter('mode', (e.currentTarget as HTMLSelectElement).value || undefined)}
      aria-label="Filter by mode"
    >
      {#each MODE_OPTIONS as opt (opt.value)}
        <option value={opt.value}>{opt.label}</option>
      {/each}
    </select>
    <span class="select-chevron" aria-hidden="true">
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5">
        <path d="M2.5 3.5L5 6.5L7.5 3.5" />
      </svg>
    </span>
  </div>

  <div class="select-wrapper">
    <select
      class="filter-select"
      value={filters.type ?? ''}
      onchange={(e) => onFilter('type', (e.currentTarget as HTMLSelectElement).value || undefined)}
      aria-label="Filter by type"
    >
      {#each TYPE_OPTIONS as opt (opt.value)}
        <option value={opt.value}>{opt.label}</option>
      {/each}
    </select>
    <span class="select-chevron" aria-hidden="true">
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5">
        <path d="M2.5 3.5L5 6.5L7.5 3.5" />
      </svg>
    </span>
  </div>

  <div class="select-wrapper">
    <select
      class="filter-select"
      value={filters.channel ?? ''}
      onchange={(e) => onFilter('channel', (e.currentTarget as HTMLSelectElement).value || undefined)}
      aria-label="Filter by channel"
    >
      {#each CHANNEL_OPTIONS as opt (opt.value)}
        <option value={opt.value}>{opt.label}</option>
      {/each}
    </select>
    <span class="select-chevron" aria-hidden="true">
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5">
        <path d="M2.5 3.5L5 6.5L7.5 3.5" />
      </svg>
    </span>
  </div>

  {#if isFiltered}
    <button class="clear-btn" onclick={onClear}>Clear</button>
  {/if}
</div>

<style>
  .filters-bar {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-wrap: wrap;
  }

  .select-wrapper {
    position: relative;
  }

  .filter-select {
    appearance: none;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-sm);
    padding: 5px 28px 5px 10px;
    font-size: 0.7rem;
    color: var(--text-secondary);
    cursor: pointer;
    transition: border-color var(--transition-fast);
  }

  .filter-select:hover {
    border-color: var(--border-hover);
  }

  .filter-select:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: 1px;
  }

  .select-chevron {
    position: absolute;
    right: 8px;
    top: 50%;
    transform: translateY(-50%);
    pointer-events: none;
    color: var(--text-muted);
  }

  .clear-btn {
    padding: 5px 12px;
    font-size: 0.7rem;
    font-weight: 500;
    color: var(--accent-primary);
    background: rgba(59, 130, 246, 0.08);
    border: 1px solid rgba(59, 130, 246, 0.2);
    border-radius: var(--radius-sm);
    transition: all var(--transition-fast);
  }

  .clear-btn:hover {
    background: rgba(59, 130, 246, 0.15);
  }
</style>
