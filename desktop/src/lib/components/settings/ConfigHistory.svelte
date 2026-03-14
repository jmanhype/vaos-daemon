<script lang="ts">
  import { onMount } from 'svelte';
  import { configRevisions } from '$lib/api/client';
  import type { ConfigRevision } from '$lib/api/types';

  let { entityType, entityId }: { entityType: string; entityId: string } = $props();

  let revisions = $state<ConfigRevision[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let expandedId = $state<number | null>(null);
  let rollingBack = $state(false);

  onMount(() => { loadRevisions(); });

  async function loadRevisions() {
    loading = true; error = null;
    try {
      const data = await configRevisions.list(entityType, entityId);
      revisions = data.revisions;
    } catch (e) { error = (e as Error).message; }
    finally { loading = false; }
  }

  async function rollback(revisionNumber: number) {
    if (rollingBack) return;
    rollingBack = true;
    try {
      await configRevisions.rollback(entityType, entityId, revisionNumber);
      await loadRevisions();
    } catch (e) { error = (e as Error).message; }
    finally { rollingBack = false; }
  }

  function toggle(id: number) { expandedId = expandedId === id ? null : id; }
  function formatDate(iso: string): string { return new Date(iso).toLocaleString(); }

  function diffFields(rev: ConfigRevision): Array<{ field: string; from: unknown; to: unknown }> {
    if (!rev.changed_fields?.length || !rev.previous_config) return [];
    return rev.changed_fields.map((f: string) => ({
      field: f, from: rev.previous_config?.[f] ?? null, to: rev.new_config[f] ?? null,
    }));
  }
</script>

{#if loading}
  <div class="loading">Loading history...</div>
{:else if error}
  <div class="error">{error}</div>
{:else if revisions.length === 0}
  <div class="empty">No configuration changes recorded.</div>
{:else}
  <div class="timeline">
    {#each revisions as rev (rev.id)}
      <div class="revision">
        <button class="rev-header" onclick={() => toggle(rev.id)}>
          <span class="rev-number">v{rev.revision_number}</span>
          <span class="rev-meta">{rev.changed_by} &middot; {formatDate(rev.inserted_at)}</span>
          <span class="rev-fields">{rev.changed_fields?.join(', ') ?? ''}</span>
          <span class="chevron" class:open={expandedId === rev.id}>&#9656;</span>
        </button>
        {#if expandedId === rev.id}
          <div class="rev-detail">
            {#if rev.change_reason}<p class="reason">{rev.change_reason}</p>{/if}
            <table class="diff-table">
              <thead><tr><th>Field</th><th>Before</th><th>After</th></tr></thead>
              <tbody>
                {#each diffFields(rev) as d}
                  <tr>
                    <td class="field-name">{d.field}</td>
                    <td class="val-old">{JSON.stringify(d.from)}</td>
                    <td class="val-new">{JSON.stringify(d.to)}</td>
                  </tr>
                {/each}
              </tbody>
            </table>
            {#if rev.revision_number > 1}
              <button class="rollback-btn" disabled={rollingBack} onclick={() => rollback(rev.revision_number)}>
                {rollingBack ? 'Rolling back...' : `Rollback to v${rev.revision_number}`}
              </button>
            {/if}
          </div>
        {/if}
      </div>
    {/each}
  </div>
{/if}

<style>
  .loading, .empty { color: var(--text-secondary, #888); padding: 16px 0; font-size: 13px; }
  .error { color: #ef4444; padding: 16px 0; font-size: 13px; }
  .timeline { display: flex; flex-direction: column; gap: 2px; }
  .revision { border: 1px solid var(--border, rgba(255, 255, 255, 0.06)); border-radius: 6px; overflow: hidden; }
  .rev-header { width: 100%; display: flex; align-items: center; gap: 8px; padding: 8px 12px; background: none; border: none; color: var(--text-primary, #e0e0e0); font-size: 12px; cursor: pointer; text-align: left; }
  .rev-header:hover { background: var(--surface-hover, rgba(255, 255, 255, 0.03)); }
  .rev-number { font-weight: 600; color: var(--accent, #3b82f6); min-width: 28px; }
  .rev-meta { color: var(--text-secondary, #888); flex-shrink: 0; }
  .rev-fields { color: var(--text-tertiary, #666); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .chevron { transition: transform 0.15s; font-size: 10px; color: var(--text-secondary, #888); }
  .chevron.open { transform: rotate(90deg); }
  .rev-detail { padding: 8px 12px 12px; border-top: 1px solid var(--border, rgba(255, 255, 255, 0.06)); background: var(--surface-elevated, rgba(255, 255, 255, 0.02)); }
  .reason { font-size: 12px; color: var(--text-secondary, #888); margin: 0 0 8px; font-style: italic; }
  .diff-table { width: 100%; border-collapse: collapse; font-size: 11px; font-family: monospace; }
  .diff-table th { text-align: left; padding: 4px 8px; color: var(--text-secondary, #888); border-bottom: 1px solid var(--border, rgba(255, 255, 255, 0.06)); }
  .diff-table td { padding: 4px 8px; border-bottom: 1px solid var(--border, rgba(255, 255, 255, 0.03)); }
  .field-name { color: var(--text-primary, #e0e0e0); font-weight: 500; }
  .val-old { color: #f87171; }
  .val-new { color: #4ade80; }
  .rollback-btn { margin-top: 8px; padding: 4px 12px; font-size: 11px; border: 1px solid var(--border, rgba(255, 255, 255, 0.1)); border-radius: 4px; background: none; color: var(--text-primary, #e0e0e0); cursor: pointer; }
  .rollback-btn:hover { background: var(--surface-hover, rgba(255, 255, 255, 0.05)); }
  .rollback-btn:disabled { opacity: 0.5; cursor: not-allowed; }
</style>
