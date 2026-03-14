<script lang="ts">
  import type { SignalStats } from "$lib/api/types";

  interface Props {
    stats: SignalStats | null;
    activeMode: string | undefined;
    onModeSelect: (mode: string | undefined) => void;
  }

  let { stats, activeMode, onModeSelect }: Props = $props();

  const MODES = ['BUILD', 'EXECUTE', 'ANALYZE', 'MAINTAIN', 'ASSIST'] as const;
</script>

<div class="mode-bar" role="toolbar" aria-label="Filter by signal mode">
  {#each MODES as mode (mode)}
    {@const count = stats?.by_mode[mode] ?? 0}
    <button
      class="mode-box"
      class:active={activeMode === mode}
      onclick={() => onModeSelect(activeMode === mode ? undefined : mode)}
      aria-pressed={activeMode === mode}
    >
      <span class="mode-label">{mode}</span>
      <span class="mode-count">{count}</span>
    </button>
  {/each}
</div>

<style>
  .mode-bar {
    display: grid;
    grid-template-columns: repeat(5, 1fr);
    gap: 6px;
  }

  .mode-box {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 4px;
    padding: 12px 8px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-sm);
    transition: all var(--transition-fast);
  }

  .mode-box:hover {
    background: var(--bg-elevated);
    border-color: var(--border-hover);
  }

  .mode-box.active {
    background: rgba(59, 130, 246, 0.1);
    border-color: var(--accent-primary);
    color: var(--text-primary);
  }

  .mode-label {
    font-size: 0.65rem;
    font-weight: 600;
    letter-spacing: 0.05em;
    color: var(--text-secondary);
  }

  .mode-box.active .mode-label {
    color: var(--accent-primary);
  }

  .mode-count {
    font-size: 1.25rem;
    font-weight: 700;
    font-family: var(--font-mono);
    color: var(--text-primary);
  }
</style>
