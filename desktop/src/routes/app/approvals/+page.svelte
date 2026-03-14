<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { slide } from 'svelte/transition';
  import { approvalsStore } from '$lib/stores/approvals.svelte';
  import type { Approval, ApprovalStatus } from '$lib/api/types';

  type FilterTab = 'all' | ApprovalStatus;

  const TABS: { id: FilterTab; label: string }[] = [
    { id: 'all',               label: 'All'      },
    { id: 'pending',           label: 'Pending'  },
    { id: 'approved',          label: 'Approved' },
    { id: 'rejected',          label: 'Rejected' },
    { id: 'revision_requested', label: 'Revision' },
  ];

  let activeFilter = $state<FilterTab>('all');
  let pendingActions = $state<Set<number>>(new Set());
  let notesMap = $state<Record<number, string>>({});

  const visibleApprovals = $derived(
    activeFilter === 'all'
      ? approvalsStore.approvals
      : approvalsStore.approvals.filter((a) => a.status === activeFilter),
  );

  function countFor(tab: FilterTab): number {
    if (tab === 'all') return approvalsStore.approvals.length;
    return approvalsStore.approvals.filter((a) => a.status === tab).length;
  }

  function formatRelative(iso: string): string {
    const diff = Date.now() - new Date(iso).getTime();
    const s = Math.floor(diff / 1000);
    if (s < 60) return 'just now';
    const m = Math.floor(s / 60);
    if (m < 60) return `${m}m ago`;
    const h = Math.floor(m / 60);
    if (h < 24) return `${h}h ago`;
    return `${Math.floor(h / 24)}d ago`;
  }

  function typeBadgeLabel(type: Approval['type']): string {
    switch (type) {
      case 'agent_create':    return 'Agent Create';
      case 'budget_change':   return 'Budget';
      case 'task_reassign':   return 'Reassign';
      case 'strategy_change': return 'Strategy';
      case 'agent_terminate': return 'Terminate';
    }
  }

  function getNotes(id: number): string {
    return notesMap[id] ?? '';
  }

  function setNotes(id: number, val: string) {
    notesMap = { ...notesMap, [id]: val };
  }

  async function handleApprove(a: Approval) {
    pendingActions = new Set([...pendingActions, a.id]);
    try {
      await approvalsStore.approve(a.id, getNotes(a.id));
    } finally {
      const next = new Set(pendingActions);
      next.delete(a.id);
      pendingActions = next;
    }
  }

  async function handleReject(a: Approval) {
    pendingActions = new Set([...pendingActions, a.id]);
    try {
      await approvalsStore.reject(a.id, getNotes(a.id));
    } finally {
      const next = new Set(pendingActions);
      next.delete(a.id);
      pendingActions = next;
    }
  }

  async function handleRevision(a: Approval) {
    pendingActions = new Set([...pendingActions, a.id]);
    try {
      await approvalsStore.requestRevision(a.id, getNotes(a.id));
    } finally {
      const next = new Set(pendingActions);
      next.delete(a.id);
      pendingActions = next;
    }
  }

  let pollTimer: ReturnType<typeof setInterval> | null = null;

  onMount(() => {
    approvalsStore.fetchApprovals();
    pollTimer = setInterval(() => approvalsStore.fetchApprovals(), 5000);
  });

  onDestroy(() => {
    if (pollTimer !== null) clearInterval(pollTimer);
  });
</script>

<div class="approvals-page">
  <header class="page-header">
    <div class="header-left">
      <h1 class="page-title">Approvals</h1>
      {#if approvalsStore.pendingCount > 0}
        <span class="pending-badge" aria-label="{approvalsStore.pendingCount} pending">
          {approvalsStore.pendingCount}
        </span>
      {/if}
    </div>

    <div class="stats-bar" role="status" aria-label="Approval statistics">
      <div class="stat stat--pending">
        <span class="stat-dot stat-dot--pending" aria-hidden="true"></span>
        <span class="stat-value">{approvalsStore.pendingCount}</span>
        <span class="stat-label">pending</span>
      </div>
      <div class="stat-divider" aria-hidden="true"></div>
      <div class="stat">
        <span class="stat-value">{approvalsStore.approvals.length}</span>
        <span class="stat-label">total</span>
      </div>
      {#if approvalsStore.loading}
        <span class="loading-spinner" aria-label="Refreshing"></span>
      {/if}
    </div>
  </header>

  <div class="filter-tabs" role="tablist" aria-label="Filter approvals">
    {#each TABS as tab (tab.id)}
      <button
        role="tab"
        aria-selected={activeFilter === tab.id}
        class="filter-tab"
        class:filter-tab--active={activeFilter === tab.id}
        onclick={() => activeFilter = tab.id}
      >
        {tab.label}
        {#if countFor(tab.id) > 0}
          <span class="tab-count" class:tab-count--pending={tab.id === 'pending'}>
            {countFor(tab.id)}
          </span>
        {/if}
      </button>
    {/each}
  </div>

  <main class="page-content" id="approvals-main">
    {#if approvalsStore.error}
      <div class="status-banner" role="alert">
        <span class="status-banner-dot"></span>
        <span class="status-banner-text">Backend offline</span>
        <span class="status-banner-hint">Start OSA backend on port 9089</span>
        <button
          class="status-banner-btn"
          onclick={() => approvalsStore.fetchApprovals()}
          aria-label="Retry fetching approvals"
        >
          Retry
        </button>
      </div>
    {/if}

    {#if visibleApprovals.length === 0 && !approvalsStore.loading}
      <div class="empty-state" role="status">
        <div class="empty-icon" aria-hidden="true">
          <svg width="48" height="48" viewBox="0 0 48 48" fill="none">
            <rect x="10" y="8" width="28" height="32" rx="4" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.4"/>
            <line x1="16" y1="18" x2="32" y2="18" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.4"/>
            <line x1="16" y1="24" x2="28" y2="24" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.25"/>
            <line x1="16" y1="30" x2="24" y2="30" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.15"/>
          </svg>
        </div>
        <p class="empty-title">No approvals</p>
        <p class="empty-subtitle">Approval requests from agents will appear here.</p>
      </div>
    {:else}
      <div class="approvals-list" role="list" aria-label="Approval list">
        {#each visibleApprovals as approval (approval.id)}
          <article
            class="approval-card"
            class:approval-card--pending={approval.status === 'pending'}
            class:approval-card--approved={approval.status === 'approved'}
            class:approval-card--rejected={approval.status === 'rejected'}
            class:approval-card--revision={approval.status === 'revision_requested'}
            role="listitem"
            transition:slide={{ duration: 180 }}
          >
            <div class="card-top">
              <div class="card-top-left">
                <span
                  class="status-dot"
                  class:status-dot--pending={approval.status === 'pending'}
                  class:status-dot--approved={approval.status === 'approved'}
                  class:status-dot--rejected={approval.status === 'rejected'}
                  class:status-dot--revision={approval.status === 'revision_requested'}
                  aria-hidden="true"
                ></span>
                <span class="type-badge">{typeBadgeLabel(approval.type)}</span>
              </div>
              <time class="card-time" datetime={approval.inserted_at}>
                {formatRelative(approval.inserted_at)}
              </time>
            </div>

            <h2 class="card-title">{approval.title}</h2>

            {#if approval.description}
              <p class="card-description">{approval.description}</p>
            {/if}

            <div class="card-meta">
              <span class="meta-label">Requested by</span>
              <span class="meta-value">{approval.requested_by}</span>
            </div>

            {#if approval.status === 'pending'}
              <div class="card-actions" transition:slide={{ duration: 140 }}>
                <textarea
                  class="notes-input"
                  placeholder="Optional notes..."
                  rows="2"
                  value={getNotes(approval.id)}
                  oninput={(e) => setNotes(approval.id, (e.currentTarget as HTMLTextAreaElement).value)}
                  aria-label="Decision notes for approval {approval.id}"
                ></textarea>
                <div class="action-btns">
                  <button
                    class="action-btn action-btn--approve"
                    onclick={() => handleApprove(approval)}
                    disabled={pendingActions.has(approval.id)}
                    aria-label="Approve: {approval.title}"
                  >
                    Approve
                  </button>
                  <button
                    class="action-btn action-btn--revision"
                    onclick={() => handleRevision(approval)}
                    disabled={pendingActions.has(approval.id)}
                    aria-label="Request revision for: {approval.title}"
                  >
                    Request Revision
                  </button>
                  <button
                    class="action-btn action-btn--reject"
                    onclick={() => handleReject(approval)}
                    disabled={pendingActions.has(approval.id)}
                    aria-label="Reject: {approval.title}"
                  >
                    Reject
                  </button>
                </div>
              </div>
            {:else}
              <div class="resolution-row">
                {#if approval.resolved_by}
                  <div class="card-meta">
                    <span class="meta-label">Resolved by</span>
                    <span class="meta-value">{approval.resolved_by}</span>
                  </div>
                {/if}
                {#if approval.resolved_at}
                  <div class="card-meta">
                    <span class="meta-label">Resolved</span>
                    <time class="meta-value" datetime={approval.resolved_at}>
                      {formatRelative(approval.resolved_at)}
                    </time>
                  </div>
                {/if}
                {#if approval.decision_notes}
                  <p class="decision-notes">{approval.decision_notes}</p>
                {/if}
              </div>
            {/if}
          </article>
        {/each}
      </div>
    {/if}
  </main>
</div>

<style>
  .approvals-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  /* ── Header ── */

  .page-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 24px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
    gap: 16px;
    flex-wrap: wrap;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .page-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.01em;
  }

  .pending-badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 20px;
    height: 20px;
    padding: 0 6px;
    border-radius: var(--radius-full);
    background: rgba(251, 191, 36, 0.18);
    color: rgba(251, 191, 36, 0.9);
    border: 1px solid rgba(251, 191, 36, 0.25);
    font-size: 0.6875rem;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }

  /* ── Stats bar ── */

  .stats-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    padding: 6px 14px;
  }

  .stat {
    display: flex;
    align-items: center;
    gap: 5px;
  }

  .stat--pending .stat-value {
    color: rgba(251, 191, 36, 0.9);
  }

  .stat-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text-tertiary);
  }

  .stat-dot--pending {
    background: rgba(251, 191, 36, 0.8);
    animation: pulse-dot 2s ease-in-out infinite;
  }

  @keyframes pulse-dot {
    0%, 100% { opacity: 1; transform: scale(1); }
    50%       { opacity: 0.6; transform: scale(0.8); }
  }

  .stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
  }

  .stat-label {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .stat-divider {
    width: 1px;
    height: 12px;
    background: rgba(255, 255, 255, 0.08);
  }

  .loading-spinner {
    width: 12px;
    height: 12px;
    border: 1.5px solid rgba(255, 255, 255, 0.1);
    border-top-color: rgba(255, 255, 255, 0.5);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
    flex-shrink: 0;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  /* ── Filter tabs ── */

  .filter-tabs {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 8px 24px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    flex-shrink: 0;
  }

  .filter-tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 5px 12px;
    border-radius: var(--radius-md);
    border: none;
    background: none;
    color: var(--text-tertiary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
    line-height: 1;
  }

  .filter-tab:hover:not(.filter-tab--active) {
    background: rgba(255, 255, 255, 0.04);
    color: var(--text-secondary);
  }

  .filter-tab--active {
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-primary);
  }

  .tab-count {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 18px;
    height: 18px;
    padding: 0 5px;
    border-radius: var(--radius-full);
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-tertiary);
    font-size: 0.625rem;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
  }

  .tab-count--pending {
    background: rgba(251, 191, 36, 0.14);
    color: rgba(251, 191, 36, 0.85);
  }

  /* ── Content ── */

  .page-content {
    flex: 1;
    overflow-y: auto;
    padding: 20px 24px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  /* ── Status banner ── */

  .status-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 16px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md);
    font-size: 0.7rem;
    color: var(--text-tertiary);
    margin-bottom: 16px;
  }

  .status-banner-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .status-banner-text {
    color: var(--text-secondary);
  }

  .status-banner-hint {
    margin-left: auto;
    color: var(--text-muted);
  }

  .status-banner-btn {
    padding: 3px 10px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.65rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
    flex-shrink: 0;
  }

  .status-banner-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
  }

  /* ── Empty state ── */

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 320px;
    gap: 12px;
    color: var(--text-tertiary);
    text-align: center;
    padding: 48px 32px;
  }

  .empty-icon {
    color: rgba(255, 255, 255, 0.12);
    margin-bottom: 4px;
  }

  .empty-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .empty-subtitle {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    max-width: 280px;
    line-height: 1.5;
  }

  /* ── Approvals list ── */

  .approvals-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  /* ── Approval card ── */

  .approval-card {
    background: rgba(255, 255, 255, 0.04);
    backdrop-filter: blur(24px);
    -webkit-backdrop-filter: blur(24px);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-xl);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    transition: border-color 0.2s ease, box-shadow 0.2s ease;
  }

  .approval-card--pending {
    border-color: rgba(251, 191, 36, 0.2);
    box-shadow:
      0 0 0 1px rgba(251, 191, 36, 0.06),
      inset 0 1px 0 rgba(251, 191, 36, 0.04);
  }

  .approval-card--approved {
    border-color: rgba(34, 197, 94, 0.15);
    opacity: 0.8;
  }

  .approval-card--rejected {
    border-color: rgba(239, 68, 68, 0.15);
    opacity: 0.75;
  }

  .approval-card--revision {
    border-color: rgba(249, 115, 22, 0.2);
  }

  /* ── Card top row ── */

  .card-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }

  .card-top-left {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  /* ── Status dot ── */

  .status-dot {
    display: block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.2);
    flex-shrink: 0;
  }

  .status-dot--pending {
    background: rgba(251, 191, 36, 0.85);
    box-shadow: 0 0 6px rgba(251, 191, 36, 0.4);
    animation: pulse-glow-yellow 2s ease-in-out infinite;
  }

  .status-dot--approved {
    background: var(--accent-success);
    box-shadow: 0 0 6px rgba(34, 197, 94, 0.4);
  }

  .status-dot--rejected {
    background: var(--accent-error);
    box-shadow: 0 0 4px rgba(239, 68, 68, 0.3);
  }

  .status-dot--revision {
    background: rgba(249, 115, 22, 0.85);
    box-shadow: 0 0 6px rgba(249, 115, 22, 0.35);
  }

  @keyframes pulse-glow-yellow {
    0%, 100% { box-shadow: 0 0 4px rgba(251, 191, 36, 0.3); }
    50%       { box-shadow: 0 0 10px rgba(251, 191, 36, 0.65); }
  }

  /* ── Type badge ── */

  .type-badge {
    display: inline-flex;
    align-items: center;
    padding: 2px 8px;
    border-radius: var(--radius-full);
    font-size: 0.625rem;
    font-weight: 600;
    letter-spacing: 0.05em;
    text-transform: uppercase;
    background: rgba(255, 255, 255, 0.07);
    color: var(--text-tertiary);
    border: 1px solid rgba(255, 255, 255, 0.08);
  }

  .card-time {
    font-size: 0.75rem;
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
    flex-shrink: 0;
  }

  /* ── Card body ── */

  .card-title {
    font-size: 0.9375rem;
    font-weight: 600;
    color: var(--text-primary);
    line-height: 1.3;
  }

  .card-description {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.5;
  }

  .card-meta {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .meta-label {
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .meta-value {
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }

  /* ── Pending actions ── */

  .card-actions {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding-top: 4px;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
  }

  .notes-input {
    width: 100%;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-md);
    color: var(--text-secondary);
    font-size: 0.8125rem;
    font-family: inherit;
    padding: 8px 10px;
    resize: vertical;
    outline: none;
    transition: border-color 0.15s;
    box-sizing: border-box;
  }

  .notes-input::placeholder {
    color: var(--text-muted);
  }

  .notes-input:focus {
    border-color: rgba(255, 255, 255, 0.16);
  }

  .action-btns {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
  }

  .action-btn {
    padding: 6px 14px;
    border-radius: var(--radius-md);
    border: 1px solid rgba(255, 255, 255, 0.1);
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-secondary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
  }

  .action-btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .action-btn--approve {
    background: rgba(34, 197, 94, 0.1);
    border-color: rgba(34, 197, 94, 0.2);
    color: rgba(34, 197, 94, 0.9);
  }

  .action-btn--approve:hover:not(:disabled) {
    background: rgba(34, 197, 94, 0.18);
    border-color: rgba(34, 197, 94, 0.35);
  }

  .action-btn--reject {
    background: rgba(239, 68, 68, 0.08);
    border-color: rgba(239, 68, 68, 0.18);
    color: rgba(239, 68, 68, 0.85);
  }

  .action-btn--reject:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.15);
    border-color: rgba(239, 68, 68, 0.3);
  }

  .action-btn--revision {
    background: rgba(249, 115, 22, 0.08);
    border-color: rgba(249, 115, 22, 0.18);
    color: rgba(249, 115, 22, 0.85);
  }

  .action-btn--revision:hover:not(:disabled) {
    background: rgba(249, 115, 22, 0.15);
    border-color: rgba(249, 115, 22, 0.3);
  }

  /* ── Resolution section ── */

  .resolution-row {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding-top: 4px;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
  }

  .decision-notes {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    line-height: 1.5;
    font-style: italic;
    padding: 6px 10px;
    background: rgba(255, 255, 255, 0.025);
    border-radius: var(--radius-sm);
    border: 1px solid rgba(255, 255, 255, 0.05);
  }
</style>
