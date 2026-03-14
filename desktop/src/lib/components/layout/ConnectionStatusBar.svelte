<script lang="ts">
  import { connectionStore } from '$lib/stores/connection.svelte';

  const status = $derived(connectionStore.status);
  const attempts = $derived(connectionStore.reconnectAttempts);
  const queueSize = $derived(connectionStore.offlineQueueSize);

  const label = $derived.by(() => {
    switch (status) {
      case 'connected': return 'Connected';
      case 'reconnecting': return `Reconnecting (attempt ${attempts})...`;
      case 'disconnected': return queueSize > 0 ? `Offline (${queueSize} queued)` : 'Offline';
      case 'connecting': return 'Connecting...';
    }
  });

  const dotClass = $derived.by(() => {
    switch (status) {
      case 'connected': return 'dot-connected';
      case 'reconnecting': return 'dot-reconnecting';
      case 'disconnected': return 'dot-offline';
      case 'connecting': return 'dot-connecting';
    }
  });
</script>

<div class="status-bar" class:expanded={status !== 'connected'}>
  <span class="dot {dotClass}" aria-hidden="true"></span>
  <span class="label" role="status" aria-live="polite">{label}</span>
</div>

<style>
  .status-bar {
    display: flex; align-items: center; gap: 6px; padding: 4px 12px;
    font-size: 11px; color: var(--text-secondary, #888); transition: all 0.2s ease;
  }
  .expanded {
    background: var(--surface-elevated, rgba(255, 255, 255, 0.03));
    border-top: 1px solid var(--border, rgba(255, 255, 255, 0.06)); padding: 6px 12px;
  }
  .dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
  .dot-connected { background: #22c55e; }
  .dot-reconnecting { background: #eab308; animation: pulse 1.5s ease-in-out infinite; }
  .dot-offline { background: #ef4444; }
  .dot-connecting { background: #3b82f6; animation: pulse 1.5s ease-in-out infinite; }
  @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.3; } }
  .label { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
</style>
