<script lang="ts">
  import { slide, fade } from 'svelte/transition';
  import { skills as skillsApi } from '$lib/api/client';
  import type { SkillDetail as SkillDetailType } from '$lib/api/types';

  interface Props {
    skillId: string;
    onClose: () => void;
    onToggle: (id: string) => void;
  }

  let { skillId, onClose, onToggle }: Props = $props();

  let detail = $state<SkillDetailType | null>(null);
  let loading = $state(true);

  $effect(() => {
    loading = true;
    skillsApi
      .get(skillId)
      .then((d) => { detail = d; })
      .catch(() => { detail = null; })
      .finally(() => { loading = false; });
  });

  const sourceLabel: Record<string, string> = {
    builtin: 'Built-in',
    user: 'User',
    evolved: 'Evolved',
  };
</script>

<!-- svelte-ignore a11y_click_events_have_key_events a11y_interactive_supports_focus -->
<div
  class="overlay"
  role="dialog"
  aria-label="Skill details"
  aria-modal="true"
  tabindex="-1"
  onclick={onClose}
  transition:fade={{ duration: 150 }}
>
  <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
  <div class="panel" onclick={(e: MouseEvent) => e.stopPropagation()} transition:slide={{ axis: 'x', duration: 200 }}>
    <header class="panel-header">
      <h2 class="panel-title">{detail?.name || skillId}</h2>
      <button class="close-btn" onclick={onClose} aria-label="Close details">
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
          <line x1="2" y1="2" x2="12" y2="12" />
          <line x1="12" y1="2" x2="2" y2="12" />
        </svg>
      </button>
    </header>

    {#if loading}
      <div class="loading">
        <span class="spinner"></span>
      </div>
    {:else if detail}
      <div class="panel-body">
        <p class="detail-desc">{detail.description || 'No description'}</p>

        <div class="meta-grid">
          <div class="meta-item">
            <span class="meta-label">Category</span>
            <span class="meta-value badge">{detail.category}</span>
          </div>
          <div class="meta-item">
            <span class="meta-label">Source</span>
            <span class="meta-value">{sourceLabel[detail.source] || detail.source}</span>
          </div>
          <div class="meta-item">
            <span class="meta-label">Priority</span>
            <span class="meta-value">{detail.priority}</span>
          </div>
          <div class="meta-item">
            <span class="meta-label">Status</span>
            <span class="meta-value" class:enabled={detail.enabled} class:disabled-text={!detail.enabled}>
              {detail.enabled ? 'Enabled' : 'Disabled'}
            </span>
          </div>
        </div>

        {#if detail.triggers.length > 0}
          <div class="section">
            <h3 class="section-title">Triggers</h3>
            <div class="trigger-list">
              {#each detail.triggers as trigger}
                <span class="trigger-tag">{trigger}</span>
              {/each}
            </div>
          </div>
        {/if}

        {#if detail.path}
          <div class="section">
            <h3 class="section-title">Path</h3>
            <code class="path-value">{detail.path}</code>
          </div>
        {/if}

        {#if detail.instructions}
          <div class="section">
            <h3 class="section-title">Instructions</h3>
            <pre class="instructions">{detail.instructions}</pre>
          </div>
        {/if}

        <div class="panel-actions">
          <button
            class="action-btn"
            class:action-btn--enable={!detail.enabled}
            class:action-btn--disable={detail.enabled}
            onclick={() => { onToggle(detail!.id); detail = { ...detail!, enabled: !detail!.enabled }; }}
          >
            {detail.enabled ? 'Disable' : 'Enable'}
          </button>
        </div>
      </div>
    {:else}
      <div class="loading">
        <p class="error-text">Failed to load skill details.</p>
      </div>
    {/if}
  </div>
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    z-index: var(--z-modal-backdrop);
    display: flex;
    justify-content: flex-end;
  }

  .panel {
    width: 420px;
    max-width: 90vw;
    height: 100%;
    background: var(--bg-secondary);
    border-left: 1px solid var(--border-default);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  .panel-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 20px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
  }

  .panel-title {
    font-size: 1rem;
    font-weight: 600;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .close-btn {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 6px;
    color: var(--text-tertiary);
    background: transparent;
    border: none;
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }

  .close-btn:hover {
    background: var(--bg-elevated);
    color: var(--text-secondary);
  }

  .panel-body {
    flex: 1;
    overflow-y: auto;
    padding: 20px;
    display: flex;
    flex-direction: column;
    gap: 20px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .detail-desc {
    font-size: 0.875rem;
    color: var(--text-secondary);
    line-height: 1.5;
  }

  .meta-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
  }

  .meta-item {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .meta-label {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .meta-value {
    font-size: 0.8125rem;
    color: var(--text-secondary);
  }

  .badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: var(--radius-full);
    background: rgba(59, 130, 246, 0.12);
    color: rgba(59, 130, 246, 0.9);
    border: 1px solid rgba(59, 130, 246, 0.2);
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    width: fit-content;
  }

  .enabled { color: var(--accent-success); }
  .disabled-text { color: var(--text-tertiary); }

  .section {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .section-title {
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .trigger-list {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .trigger-tag {
    font-size: 0.75rem;
    padding: 2px 8px;
    border-radius: var(--radius-xs);
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
    color: var(--text-secondary);
    font-family: ui-monospace, monospace;
  }

  .path-value {
    font-family: ui-monospace, monospace;
    font-size: 0.75rem;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.03);
    padding: 6px 10px;
    border-radius: var(--radius-sm);
    border: 1px solid rgba(255, 255, 255, 0.05);
    word-break: break-all;
    user-select: text;
  }

  .instructions {
    font-family: ui-monospace, monospace;
    font-size: 0.75rem;
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: var(--radius-sm);
    padding: 12px;
    white-space: pre-wrap;
    word-break: break-word;
    max-height: 400px;
    overflow-y: auto;
    line-height: 1.5;
    margin: 0;
  }

  .panel-actions {
    padding-top: 8px;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
  }

  .action-btn {
    padding: 8px 20px;
    border-radius: var(--radius-sm);
    border: 1px solid rgba(255, 255, 255, 0.12);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
  }

  .action-btn--enable {
    background: rgba(34, 197, 94, 0.12);
    color: rgba(34, 197, 94, 0.9);
    border-color: rgba(34, 197, 94, 0.25);
  }

  .action-btn--enable:hover {
    background: rgba(34, 197, 94, 0.2);
  }

  .action-btn--disable {
    background: rgba(239, 68, 68, 0.08);
    color: rgba(239, 68, 68, 0.8);
    border-color: rgba(239, 68, 68, 0.2);
  }

  .action-btn--disable:hover {
    background: rgba(239, 68, 68, 0.15);
  }

  .loading {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 48px;
  }

  .spinner {
    width: 20px;
    height: 20px;
    border: 2px solid rgba(255, 255, 255, 0.1);
    border-top-color: rgba(255, 255, 255, 0.5);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .error-text {
    font-size: 0.875rem;
    color: var(--text-tertiary);
  }
</style>
