<!-- src/lib/components/palette/CommandPalette.svelte -->
<!-- Spotlight-style command palette. Triggered by Cmd/Ctrl+K. -->
<script lang="ts">
  import { fly } from 'svelte/transition';
  import { paletteStore } from '$lib/stores/palette.svelte';
  import type { PaletteCommand, CommandCategory } from '$lib/stores/palette.svelte';

  // ── Input binding & keyboard handling ────────────────────────────────────────

  let inputEl = $state<HTMLInputElement | null>(null);

  // Auto-focus the input whenever the palette opens
  $effect(() => {
    if (paletteStore.isOpen && inputEl) {
      // Tick required so the element is visible before focusing
      requestAnimationFrame(() => inputEl?.focus());
    }
  });

  function handleKeyDown(e: KeyboardEvent) {
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault();
        paletteStore.moveDown();
        scrollSelectedIntoView();
        break;
      case 'ArrowUp':
        e.preventDefault();
        paletteStore.moveUp();
        scrollSelectedIntoView();
        break;
      case 'Enter':
        e.preventDefault();
        void paletteStore.executeSelected();
        break;
      case 'Escape':
        e.preventDefault();
        paletteStore.close();
        break;
    }
  }

  function scrollSelectedIntoView() {
    requestAnimationFrame(() => {
      const el = document.querySelector<HTMLElement>('[data-palette-selected="true"]');
      el?.scrollIntoView({ block: 'nearest' });
    });
  }

  // ── Category labels ──────────────────────────────────────────────────────────

  const CATEGORY_LABELS: Record<CommandCategory, string> = {
    recent: 'Recent',
    navigation: 'Navigation',
    actions: 'Actions',
    commands: 'Commands',
  };

  // ── Flat index tracking ───────────────────────────────────────────────────────
  // We render groups in order: recent → navigation → actions → commands.
  // flatFiltered mirrors that order. We use indexOf on the flat list to assign
  // the global index to each item for selection highlighting.

  function globalIndex(cmd: PaletteCommand): number {
    return paletteStore.flatFiltered.indexOf(cmd);
  }

  function isSelected(cmd: PaletteCommand): boolean {
    return globalIndex(cmd) === paletteStore.selectedIndex;
  }

  // ── Grouped sections for rendering ───────────────────────────────────────────

  interface Section {
    category: CommandCategory;
    label: string;
    items: PaletteCommand[];
  }

  const sections = $derived.by((): Section[] => {
    const g = paletteStore.grouped;
    const out: Section[] = [];
    const cats: CommandCategory[] = ['recent', 'navigation', 'actions', 'commands'];
    for (const cat of cats) {
      if (g[cat].length > 0) {
        out.push({ category: cat, label: CATEGORY_LABELS[cat], items: g[cat] });
      }
    }
    return out;
  });

  const hasResults = $derived(paletteStore.totalVisible > 0);
</script>

<!-- Backdrop -->
<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
<div
  class="palette-backdrop"
  onclick={() => paletteStore.close()}
  aria-hidden="true"
>
</div>

<!-- Palette card -->
<div
  class="palette-card"
  role="dialog"
  aria-label="Command palette"
  aria-modal="true"
  tabindex="-1"
  transition:fly={{ y: -10, duration: 150, opacity: 0 }}
  onkeydown={handleKeyDown}
>
  <!-- Search input row -->
  <div class="palette-search-row">
    <svg class="palette-search-icon" viewBox="0 0 20 20" fill="none" aria-hidden="true">
      <circle cx="8.5" cy="8.5" r="5.5" stroke="currentColor" stroke-width="1.5"/>
      <path d="M13.5 13.5L17 17" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
    </svg>
    <input
      bind:this={inputEl}
      type="text"
      class="palette-input"
      placeholder="Search commands..."
      autocomplete="off"
      autocorrect="off"
      spellcheck={false}
      value={paletteStore.query}
      oninput={(e) => paletteStore.setQuery((e.currentTarget as HTMLInputElement).value)}
      aria-label="Command search"
      aria-autocomplete="list"
      aria-controls="palette-results"
      aria-activedescendant={hasResults ? `palette-item-${paletteStore.selectedIndex}` : undefined}
    />
    <kbd class="palette-esc-hint" aria-label="Press Escape to close">esc</kbd>
  </div>

  <div class="palette-divider"></div>

  <!-- Results -->
  <div class="palette-results" id="palette-results" role="listbox" aria-label="Command results">
    {#if hasResults}
      {#each sections as section (section.category)}
        <div class="palette-group" role="group" aria-label={section.label}>
          <div class="palette-group-label">{section.label}</div>
          {#each section.items as cmd (cmd.id)}
            {@const idx = globalIndex(cmd)}
            {@const selected = isSelected(cmd)}
            <button
              id="palette-item-{idx}"
              class="palette-item"
              class:palette-item--selected={selected}
              role="option"
              aria-selected={selected}
              data-palette-selected={selected}
              onclick={() => void paletteStore.execute(cmd)}
            >
              <!-- Icon -->
              <span class="palette-item-icon" aria-hidden="true">
                {#if cmd.icon === 'chat'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 01-2 2H7l-4 4V5a2 2 0 012-2h14a2 2 0 012 2z"/></svg>
                {:else if cmd.icon === 'agents'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16" rx="2"/><circle cx="9" cy="10" r="1.5"/><circle cx="15" cy="10" r="1.5"/><path d="M9 16c.85.63 1.885 1 3 1s2.15-.37 3-1"/></svg>
                {:else if cmd.icon === 'models'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 000 20 14.5 14.5 0 000-20"/><path d="M2 12h20"/></svg>
                {:else if cmd.icon === 'terminal'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
                {:else if cmd.icon === 'settings'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 010 2.83 2 2 0 01-2.83 0l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-4 0v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83-2.83l.06-.06A1.65 1.65 0 004.68 15a1.65 1.65 0 00-1.51-1H3a2 2 0 010-4h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 012.83-2.83l.06.06A1.65 1.65 0 009 4.68a1.65 1.65 0 001-1.51V3a2 2 0 014 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 2.83l-.06.06A1.65 1.65 0 0019.4 9a1.65 1.65 0 001.51 1H21a2 2 0 010 4h-.09a1.65 1.65 0 00-1.51 1z"/></svg>
                {:else if cmd.icon === 'plus'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
                {:else if cmd.icon === 'trash'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/></svg>
                {:else if cmd.icon === 'bolt'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>
                {:else if cmd.icon === 'link'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 007.54.54l3-3a5 5 0 00-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 00-7.54-.54l-3 3a5 5 0 007.07 7.07l1.71-1.71"/></svg>
                {:else if cmd.icon === 'refresh'}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15"/></svg>
                {:else}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 17l6-6-6-6"/><line x1="12" y1="19" x2="20" y2="19"/></svg>
                {/if}
              </span>

              <!-- Text -->
              <span class="palette-item-text">
                <span class="palette-item-name">{cmd.name}</span>
                {#if cmd.description}
                  <span class="palette-item-desc">{cmd.description}</span>
                {/if}
              </span>

              <!-- Shortcut -->
              {#if cmd.shortcut}
                <kbd class="palette-item-shortcut">{cmd.shortcut}</kbd>
              {/if}
            </button>
          {/each}
        </div>
      {/each}
    {:else}
      <div class="palette-empty" role="status">
        {#if paletteStore.query}
          No commands match "<span class="palette-empty-query">{paletteStore.query}</span>"
        {:else}
          Start typing to search commands
        {/if}
      </div>
    {/if}
  </div>

  <!-- Footer hint -->
  <div class="palette-footer" aria-hidden="true">
    <span><kbd>↑</kbd><kbd>↓</kbd> navigate</span>
    <span><kbd>↵</kbd> run</span>
    <span><kbd>esc</kbd> close</span>
  </div>
</div>

<style>
  /* ── Backdrop ─────────────────────────────────────────────────────────────── */

  .palette-backdrop {
    position: fixed;
    inset: 0;
    z-index: calc(var(--z-modal) - 1);
    background: rgba(0, 0, 0, 0.6);
    backdrop-filter: blur(2px);
    -webkit-backdrop-filter: blur(2px);
  }

  /* ── Card ─────────────────────────────────────────────────────────────────── */

  .palette-card {
    position: fixed;
    top: 18%;
    left: 50%;
    transform: translateX(-50%);
    z-index: var(--z-modal);

    width: min(560px, calc(100vw - 32px));
    max-height: 420px;

    display: flex;
    flex-direction: column;

    background: rgba(16, 16, 18, 0.95);
    backdrop-filter: blur(40px) saturate(1.8);
    -webkit-backdrop-filter: blur(40px) saturate(1.8);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 16px;
    box-shadow:
      0 24px 64px rgba(0, 0, 0, 0.7),
      0 4px 16px rgba(0, 0, 0, 0.4),
      inset 0 1px 0 rgba(255, 255, 255, 0.08);

    overflow: hidden;
  }

  /* ── Search row ───────────────────────────────────────────────────────────── */

  .palette-search-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 14px 16px;
    flex-shrink: 0;
  }

  .palette-search-icon {
    width: 18px;
    height: 18px;
    color: rgba(255, 255, 255, 0.35);
    flex-shrink: 0;
  }

  .palette-input {
    flex: 1;
    background: transparent;
    border: none;
    outline: none;
    color: rgba(255, 255, 255, 0.95);
    font-size: 15px;
    font-family: var(--font-sans);
    line-height: 1.4;
    caret-color: var(--accent-primary);
  }

  .palette-input::placeholder {
    color: rgba(255, 255, 255, 0.28);
  }

  .palette-esc-hint {
    flex-shrink: 0;
    font-family: var(--font-sans);
    font-size: 11px;
    color: rgba(255, 255, 255, 0.3);
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 5px;
    padding: 2px 6px;
  }

  /* ── Divider ──────────────────────────────────────────────────────────────── */

  .palette-divider {
    height: 1px;
    background: linear-gradient(
      90deg,
      transparent,
      rgba(255, 255, 255, 0.08),
      transparent
    );
    flex-shrink: 0;
  }

  /* ── Results ──────────────────────────────────────────────────────────────── */

  .palette-results {
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    padding: 6px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.12) transparent;
  }

  .palette-results::-webkit-scrollbar {
    width: 4px;
  }

  .palette-results::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.12);
    border-radius: 9999px;
  }

  /* ── Group ────────────────────────────────────────────────────────────────── */

  .palette-group {
    margin-bottom: 4px;
  }

  .palette-group-label {
    padding: 6px 10px 4px;
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.28);
    user-select: none;
  }

  /* ── Item ─────────────────────────────────────────────────────────────────── */

  .palette-item {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 8px 10px;
    border: none;
    border-radius: 8px;
    background: transparent;
    color: rgba(255, 255, 255, 0.85);
    cursor: pointer;
    text-align: left;
    transition: background 80ms ease;
  }

  .palette-item:hover {
    background: rgba(255, 255, 255, 0.06);
  }

  .palette-item--selected {
    background: rgba(59, 130, 246, 0.18);
    color: rgba(255, 255, 255, 0.95);
  }

  .palette-item--selected:hover {
    background: rgba(59, 130, 246, 0.22);
  }

  /* ── Item: icon ───────────────────────────────────────────────────────────── */

  .palette-item-icon {
    font-size: 16px;
    width: 24px;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    border-radius: 6px;
    background: rgba(255, 255, 255, 0.06);
    line-height: 1;
  }

  .palette-item-icon--slash {
    font-family: var(--font-mono);
    font-size: 13px;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.4);
  }

  /* ── Item: text ───────────────────────────────────────────────────────────── */

  .palette-item-text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .palette-item-name {
    font-size: 14px;
    font-weight: 500;
    color: inherit;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .palette-item-desc {
    font-size: 12px;
    color: rgba(255, 255, 255, 0.38);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .palette-item--selected .palette-item-desc {
    color: rgba(255, 255, 255, 0.5);
  }

  /* ── Item: shortcut ───────────────────────────────────────────────────────── */

  .palette-item-shortcut {
    flex-shrink: 0;
    font-family: var(--font-sans);
    font-size: 11px;
    color: rgba(255, 255, 255, 0.3);
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 5px;
    padding: 2px 6px;
  }

  .palette-item--selected .palette-item-shortcut {
    color: rgba(59, 130, 246, 0.8);
    background: rgba(59, 130, 246, 0.1);
    border-color: rgba(59, 130, 246, 0.2);
  }

  /* ── Empty state ──────────────────────────────────────────────────────────── */

  .palette-empty {
    padding: 28px 16px;
    text-align: center;
    font-size: 13px;
    color: rgba(255, 255, 255, 0.3);
  }

  .palette-empty-query {
    color: rgba(255, 255, 255, 0.55);
    font-style: italic;
  }

  /* ── Footer ───────────────────────────────────────────────────────────────── */

  .palette-footer {
    flex-shrink: 0;
    display: flex;
    gap: 16px;
    padding: 8px 16px;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
    font-size: 11px;
    color: rgba(255, 255, 255, 0.22);
    user-select: none;
  }

  .palette-footer kbd {
    display: inline-block;
    font-family: var(--font-sans);
    font-size: 10px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 4px;
    padding: 1px 4px;
    margin-right: 2px;
    color: rgba(255, 255, 255, 0.35);
  }
</style>
