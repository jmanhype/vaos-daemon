<script lang="ts">
  import type { LogLevel, LogSource } from "$lib/mock-data";

  type FilterSource = LogSource | "all";

  // ── Props ─────────────────────────────────────────────────────────────────

  interface Props {
    filterLevel: LogLevel | "all";
    filterSource: FilterSource;
    searchQuery: string;
    totalCount: number;
    filteredCount: number;
    onFilterLevel: (level: LogLevel | "all") => void;
    onFilterSource: (source: FilterSource) => void;
    onSearch: (query: string) => void;
    onClear: () => void;
  }

  let {
    filterLevel,
    filterSource,
    searchQuery,
    totalCount,
    filteredCount,
    onFilterLevel,
    onFilterSource,
    onSearch,
    onClear,
  }: Props = $props();

  // ── Options ───────────────────────────────────────────────────────────────

  const LEVEL_OPTIONS: { value: LogLevel | "all"; label: string }[] = [
    { value: "all",   label: "All levels" },
    { value: "info",  label: "Info" },
    { value: "warn",  label: "Warn" },
    { value: "error", label: "Error" },
    { value: "debug", label: "Debug" },
  ];

  const SOURCE_OPTIONS: { value: FilterSource; label: string }[] = [
    { value: "all",             label: "All sources" },
    { value: "agent",           label: "Agent" },
    { value: "system",          label: "System" },
    { value: "user",            label: "User" },
    { value: "api",             label: "API" },
    { value: "session",         label: "Session" },
    { value: "tool",            label: "Tool" },
    { value: "command-center",  label: "Command Center" },
  ];

  // ── Derived ───────────────────────────────────────────────────────────────

  const isFiltered = $derived(
    filterLevel !== "all" ||
    filterSource !== "all" ||
    searchQuery.trim() !== "",
  );

  const showingAll = $derived(filteredCount === totalCount);
</script>

<div class="filters-bar" role="search" aria-label="Filter activity logs">

  <!-- Level dropdown -->
  <div class="filter-group">
    <label class="filter-label" for="filter-level">Level</label>
    <div class="select-wrapper">
      <select
        id="filter-level"
        class="filter-select"
        value={filterLevel}
        onchange={(e) => onFilterLevel((e.currentTarget as HTMLSelectElement).value as LogLevel | "all")}
        aria-label="Filter by log level"
      >
        {#each LEVEL_OPTIONS as opt (opt.value)}
          <option value={opt.value}>{opt.label}</option>
        {/each}
      </select>
      <span class="select-chevron" aria-hidden="true">
        <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round">
          <polyline points="2,3.5 5,6.5 8,3.5"/>
        </svg>
      </span>
    </div>
  </div>

  <!-- Source dropdown -->
  <div class="filter-group">
    <label class="filter-label" for="filter-source">Source</label>
    <div class="select-wrapper">
      <select
        id="filter-source"
        class="filter-select"
        value={filterSource}
        onchange={(e) => onFilterSource((e.currentTarget as HTMLSelectElement).value as FilterSource)}
        aria-label="Filter by log source"
      >
        {#each SOURCE_OPTIONS as opt (opt.value)}
          <option value={opt.value}>{opt.label}</option>
        {/each}
      </select>
      <span class="select-chevron" aria-hidden="true">
        <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round">
          <polyline points="2,3.5 5,6.5 8,3.5"/>
        </svg>
      </span>
    </div>
  </div>

  <!-- Search input -->
  <div class="search-wrapper">
    <span class="search-icon" aria-hidden="true">
      <svg width="13" height="13" viewBox="0 0 13 13" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round">
        <circle cx="5.5" cy="5.5" r="4"/>
        <line x1="8.75" y1="8.75" x2="11.5" y2="11.5"/>
      </svg>
    </span>
    <input
      type="search"
      class="glass-input search-input"
      placeholder="Search messages, sources..."
      value={searchQuery}
      oninput={(e) => onSearch((e.currentTarget as HTMLInputElement).value)}
      aria-label="Search log messages"
    />
  </div>

  <!-- Spacer -->
  <div class="spacer"></div>

  <!-- Clear button — only when filters are active -->
  {#if isFiltered}
    <button
      class="clear-btn"
      onclick={onClear}
      aria-label="Clear all filters"
    >
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
        <line x1="1.5" y1="1.5" x2="8.5" y2="8.5"/>
        <line x1="8.5" y1="1.5" x2="1.5" y2="8.5"/>
      </svg>
      Clear
    </button>
  {/if}

  <!-- Count badge -->
  <div class="count-badge" role="status" aria-live="polite" aria-label="Log count">
    {#if showingAll}
      <span class="count-value">{totalCount}</span>
      <span class="count-label">logs</span>
    {:else}
      <span class="count-value">{filteredCount}</span>
      <span class="count-sep">of</span>
      <span class="count-total">{totalCount}</span>
      <span class="count-label">logs</span>
    {/if}
  </div>

</div>

<style>
  /* ── Bar layout ── */

  .filters-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 0;
    flex-wrap: wrap;
  }

  /* ── Filter group (label + select) ── */

  .filter-group {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .filter-label {
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-tertiary);
    white-space: nowrap;
    user-select: none;
  }

  /* ── Select wrapper ── */

  .select-wrapper {
    position: relative;
    display: inline-flex;
    align-items: center;
  }

  .filter-select {
    appearance: none;
    -webkit-appearance: none;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    font-size: 0.75rem;
    font-weight: 500;
    font-family: inherit;
    padding: 5px 26px 5px 10px;
    cursor: pointer;
    outline: none;
    transition: border-color 0.15s, background 0.15s;
    min-width: 116px;
  }

  .filter-select:hover {
    background: rgba(255, 255, 255, 0.08);
    border-color: rgba(255, 255, 255, 0.14);
    color: var(--text-primary);
  }

  .filter-select:focus-visible {
    border-color: var(--accent-primary);
    box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.2);
  }

  /* native option elements inherit the OS dark style in Tauri */
  .filter-select option {
    background: #1e1e1e;
    color: var(--text-primary);
  }

  .select-chevron {
    position: absolute;
    right: 8px;
    pointer-events: none;
    color: var(--text-tertiary);
    display: flex;
    align-items: center;
  }

  /* ── Search ── */

  .search-wrapper {
    position: relative;
    display: flex;
    align-items: center;
    min-width: 200px;
    flex: 1;
    max-width: 320px;
  }

  .search-icon {
    position: absolute;
    left: 10px;
    color: var(--text-tertiary);
    pointer-events: none;
    display: flex;
    align-items: center;
  }

  .search-input {
    padding-left: 30px !important;
    padding-top: 6px !important;
    padding-bottom: 6px !important;
    font-size: 0.8125rem !important;
    border-radius: var(--radius-sm) !important;
  }

  /* Clear the browser-native search cancel icon */
  .search-input::-webkit-search-cancel-button {
    -webkit-appearance: none;
  }

  /* ── Spacer ── */

  .spacer {
    flex: 1;
    min-width: 0;
  }

  /* ── Clear button ── */

  .clear-btn {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 5px 10px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-sm);
    color: var(--text-tertiary);
    font-size: 0.75rem;
    font-weight: 500;
    transition: all 0.15s;
    white-space: nowrap;
  }

  .clear-btn:hover {
    background: rgba(255, 255, 255, 0.08);
    border-color: rgba(255, 255, 255, 0.14);
    color: var(--text-secondary);
  }

  /* ── Count badge ── */

  .count-badge {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 5px 10px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    white-space: nowrap;
    flex-shrink: 0;
  }

  .count-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
  }

  .count-sep,
  .count-total {
    font-size: 0.75rem;
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
  }

  .count-label {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
  }
</style>
