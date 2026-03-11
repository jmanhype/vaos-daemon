<script lang="ts">
  import { tick } from "svelte";
  import type { Session } from "$api/types";

  interface Props {
    session: Session;
    isActive: boolean;
    onSelect: (id: string) => void;
    onRename: (id: string, title: string) => void;
    onDelete: (id: string) => void;
  }

  let { session, isActive, onSelect, onRename, onDelete }: Props = $props();

  // ── Edit mode ─────────────────────────────────────────────────────────────

  let editing = $state(false);
  let editValue = $state("");
  let inputEl = $state<HTMLInputElement | null>(null);

  async function startEdit() {
    editValue = session.title ?? "";
    editing = true;
    await tick();
    inputEl?.select();
  }

  function commitEdit() {
    const trimmed = editValue.trim();
    if (trimmed && trimmed !== session.title) {
      onRename(session.id, trimmed);
    }
    editing = false;
  }

  function cancelEdit() {
    editing = false;
  }

  function handleEditKeydown(e: KeyboardEvent) {
    if (e.key === "Enter") {
      e.preventDefault();
      commitEdit();
    } else if (e.key === "Escape") {
      e.preventDefault();
      cancelEdit();
    }
  }

  // ── Context menu ──────────────────────────────────────────────────────────

  let menuOpen = $state(false);
  let menuX = $state(0);
  let menuY = $state(0);

  function openContextMenu(e: MouseEvent) {
    e.preventDefault();
    menuX = e.clientX;
    menuY = e.clientY;
    menuOpen = true;
  }

  function closeContextMenu() {
    menuOpen = false;
  }

  // ── Delete confirmation ───────────────────────────────────────────────────

  let confirmDelete = $state(false);

  function requestDelete() {
    closeContextMenu();
    confirmDelete = true;
  }

  function confirmDeletion() {
    onDelete(session.id);
    confirmDelete = false;
  }

  function cancelDelete() {
    confirmDelete = false;
  }

  // ── Relative time ─────────────────────────────────────────────────────────

  function relativeTime(iso: string): string {
    const diff = Date.now() - new Date(iso).getTime();
    const s = Math.floor(diff / 1000);
    if (s < 60) return "just now";
    const m = Math.floor(s / 60);
    if (m < 60) return `${m}m ago`;
    const h = Math.floor(m / 60);
    if (h < 24) return `${h}h ago`;
    const d = Math.floor(h / 24);
    if (d < 7) return `${d}d ago`;
    return new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric" });
  }

  const timeAgo = $derived(session.created_at ? relativeTime(session.created_at) : "");

  // ── Long-press (mobile / trackpad) for context menu ──────────────────────

  let longPressTimer: ReturnType<typeof setTimeout> | null = null;

  function startLongPress(e: PointerEvent) {
    longPressTimer = setTimeout(() => {
      openContextMenu(e as unknown as MouseEvent);
    }, 500);
  }

  function cancelLongPress() {
    if (longPressTimer !== null) {
      clearTimeout(longPressTimer);
      longPressTimer = null;
    }
  }
</script>

<!-- Close context menu on outside click -->
<svelte:window
  onclick={(e) => {
    if (menuOpen) {
      const target = e.target as HTMLElement;
      if (!target.closest(".ctx-menu")) closeContextMenu();
    }
  }}
/>

<div
  class="session-item"
  class:active={isActive}
  role="option"
  aria-selected={isActive}
  tabindex="0"
  onclick={() => onSelect(session.id)}
  ondblclick={startEdit}
  oncontextmenu={openContextMenu}
  onpointerdown={startLongPress}
  onpointerup={cancelLongPress}
  onpointercancel={cancelLongPress}
  onkeydown={(e) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      onSelect(session.id);
    } else if (e.key === "Delete" || e.key === "Backspace") {
      requestDelete();
    }
  }}
>
  <!-- Active indicator bar -->
  {#if isActive}
    <span class="active-bar" aria-hidden="true"></span>
  {/if}

  <div class="item-body">
    <!-- Title row -->
    <div class="title-row">
      {#if editing}
        <input
          bind:this={inputEl}
          bind:value={editValue}
          class="title-input"
          onclick={(e) => e.stopPropagation()}
          onkeydown={handleEditKeydown}
          onblur={commitEdit}
          aria-label="Rename session"
          type="text"
        />
      {:else}
        <span class="title">{session.title}</span>
      {/if}

      <!-- Message count badge -->
      {#if session.message_count > 0}
        <span class="badge" aria-label="{session.message_count} messages">
          {session.message_count > 99 ? "99+" : session.message_count}
        </span>
      {/if}
    </div>

    <!-- Timestamp -->
    <span class="timestamp">{timeAgo}</span>
  </div>
</div>

<!-- Context menu -->
{#if menuOpen}
  <div
    class="ctx-menu"
    role="menu"
    style:left="{menuX}px"
    style:top="{menuY}px"
  >
    <button
      class="ctx-item"
      role="menuitem"
      onclick={(e) => { e.stopPropagation(); closeContextMenu(); startEdit(); }}
    >
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
          d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L10.582 16.07a4.5 4.5 0 01-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 011.13-1.897l8.932-8.931zm0 0L19.5 7.125" />
      </svg>
      Rename
    </button>
    <button
      class="ctx-item ctx-item--danger"
      role="menuitem"
      onclick={(e) => { e.stopPropagation(); requestDelete(); }}
    >
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
          d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 00-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 00-7.5 0" />
      </svg>
      Delete
    </button>
  </div>
{/if}

<!-- Delete confirmation -->
{#if confirmDelete}
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div
    class="confirm-backdrop"
    role="presentation"
    onclick={cancelDelete}
    onkeydown={(e) => e.key === "Escape" && cancelDelete()}
  >
    <div
      class="confirm-dialog"
      role="alertdialog"
      aria-modal="true"
      aria-label="Confirm delete session"
      tabindex="-1"
      onclick={(e) => e.stopPropagation()}
    >
      <p class="confirm-title">Delete session?</p>
      <p class="confirm-body">"{session.title}" will be permanently removed.</p>
      <div class="confirm-actions">
        <button class="confirm-btn confirm-btn--cancel" onclick={cancelDelete}>Cancel</button>
        <button class="confirm-btn confirm-btn--danger" onclick={confirmDeletion}>Delete</button>
      </div>
    </div>
  </div>
{/if}

<style>
  /* ── Item ─────────────────────────────────────────────────────────────────── */
  .session-item {
    position: relative;
    display: flex;
    align-items: stretch;
    padding: 0;
    border-radius: var(--radius-sm);
    cursor: pointer;
    transition: background var(--transition-fast);
    outline: none;
    user-select: none;
  }

  .session-item:hover {
    background: rgba(255, 255, 255, 0.05);
  }

  .session-item:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: -2px;
  }

  .session-item.active {
    background: rgba(59, 130, 246, 0.08);
  }

  /* ── Active bar ───────────────────────────────────────────────────────────── */
  .active-bar {
    flex-shrink: 0;
    width: 2px;
    border-radius: 0 2px 2px 0;
    background: var(--accent-primary);
    box-shadow: 0 0 8px rgba(59, 130, 246, 0.5);
    align-self: stretch;
    margin-right: 0;
  }

  /* ── Body ─────────────────────────────────────────────────────────────────── */
  .item-body {
    flex: 1;
    min-width: 0;
    padding: 8px 10px;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .title-row {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
  }

  .title {
    flex: 1;
    min-width: 0;
    font-size: 13px;
    font-weight: 500;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .active .title {
    color: var(--text-primary);
  }

  .title-input {
    flex: 1;
    min-width: 0;
    font-size: 13px;
    font-weight: 500;
    color: var(--text-primary);
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid var(--border-focus);
    border-radius: var(--radius-xs);
    padding: 1px 6px;
    outline: none;
    box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.25);
  }

  /* ── Badge ────────────────────────────────────────────────────────────────── */
  .badge {
    flex-shrink: 0;
    font-size: 10px;
    font-weight: 600;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-full);
    padding: 0 5px;
    line-height: 16px;
    font-family: var(--font-mono);
  }

  /* ── Timestamp ────────────────────────────────────────────────────────────── */
  .timestamp {
    font-size: 11px;
    color: var(--text-tertiary);
  }

  /* ── Context menu ─────────────────────────────────────────────────────────── */
  .ctx-menu {
    position: fixed;
    z-index: var(--z-popover);
    background: rgba(28, 28, 30, 0.95);
    backdrop-filter: blur(24px);
    -webkit-backdrop-filter: blur(24px);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-sm);
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
    padding: 4px;
    min-width: 140px;
    animation: ctx-appear 100ms cubic-bezier(0.4, 0, 0.2, 1);
  }

  @keyframes ctx-appear {
    from { opacity: 0; transform: scale(0.95); }
    to   { opacity: 1; transform: scale(1); }
  }

  .ctx-item {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 7px 10px;
    border-radius: var(--radius-xs);
    background: transparent;
    border: none;
    color: var(--text-secondary);
    font-size: 13px;
    text-align: left;
    cursor: pointer;
    transition: background var(--transition-fast), color var(--transition-fast);
  }

  .ctx-item:hover {
    background: rgba(255, 255, 255, 0.07);
    color: var(--text-primary);
  }

  .ctx-item--danger:hover {
    background: rgba(239, 68, 68, 0.12);
    color: var(--accent-error);
  }

  /* ── Delete confirmation ──────────────────────────────────────────────────── */
  .confirm-backdrop {
    position: fixed;
    inset: 0;
    z-index: var(--z-modal-backdrop);
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .confirm-dialog {
    background: rgba(28, 28, 30, 0.96);
    backdrop-filter: blur(32px);
    -webkit-backdrop-filter: blur(32px);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-md);
    box-shadow: 0 16px 48px rgba(0, 0, 0, 0.6);
    padding: 20px;
    width: 280px;
    animation: ctx-appear 150ms cubic-bezier(0.4, 0, 0.2, 1);
  }

  .confirm-title {
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 6px;
  }

  .confirm-body {
    font-size: 13px;
    color: var(--text-tertiary);
    margin-bottom: 16px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .confirm-actions {
    display: flex;
    gap: 8px;
    justify-content: flex-end;
  }

  .confirm-btn {
    padding: 6px 14px;
    border-radius: var(--radius-sm);
    font-size: 13px;
    font-weight: 500;
    border: 1px solid var(--border-default);
    cursor: pointer;
    transition: background var(--transition-fast), color var(--transition-fast);
  }

  .confirm-btn--cancel {
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-secondary);
  }

  .confirm-btn--cancel:hover {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text-primary);
  }

  .confirm-btn--danger {
    background: rgba(239, 68, 68, 0.15);
    color: var(--accent-error);
    border-color: rgba(239, 68, 68, 0.3);
  }

  .confirm-btn--danger:hover {
    background: rgba(239, 68, 68, 0.25);
  }
</style>
