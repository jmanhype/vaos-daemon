<script lang="ts">
  import type { ScheduledRun } from '$lib/api/types';
  import { scheduledTasksStore } from '$lib/stores/scheduledTasks.svelte';

  interface Props { run: ScheduledRun; taskName?: string; onClose: () => void; onRerun?: (taskId: string) => void; }
  let { run, taskName = '', onClose, onRerun }: Props = $props();

  const output = $derived(scheduledTasksStore.activeRunOutput);
  const streaming = $derived(scheduledTasksStore.activeRunStreaming);

  function fmtDur(ms?: number): string { if (!ms) return '—'; if (ms < 1000) return `${ms}ms`; const s = Math.floor(ms / 1000); if (s < 60) return `${s}s`; return `${Math.floor(s / 60)}m ${s % 60}s`; }
  function statusClr(s: ScheduledRun['status']): string { switch (s) { case 'succeeded': return 'rgba(34,197,94,0.85)'; case 'failed': return 'rgba(239,68,68,0.85)'; case 'running': return 'rgba(245,158,11,0.85)'; default: return 'rgba(255,255,255,0.5)'; } }
  function trigLbl(t: ScheduledRun['trigger_type']): string { switch (t) { case 'schedule': return 'Scheduled'; case 'manual': return 'Manual'; case 'event': return 'Event'; case 'assignment': return 'Assignment'; } }
</script>

<div class="rd">
  <div class="rd-header">
    <div class="rd-left">
      {#if taskName}<span class="rd-name">{taskName}</span>{/if}
      <span class="rd-badge" style="color:{statusClr(run.status)};border-color:{statusClr(run.status)}">{run.status}{#if streaming}<span class="rd-pulse" aria-hidden="true"></span>{/if}</span>
      <span class="rd-trigger">{trigLbl(run.trigger_type)}</span>
      <span class="rd-dur">{fmtDur(run.duration_ms)}</span>
    </div>
    <button class="rd-close" onclick={onClose} aria-label="Close"><svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><line x1="1.5" y1="1.5" x2="8.5" y2="8.5"/><line x1="8.5" y1="1.5" x2="1.5" y2="8.5"/></svg></button>
  </div>
  <div class="rd-output">
    {#if output}<pre class="rd-stdout">{output}</pre>
    {:else if run.error_message}<pre class="rd-stdout rd-stdout--err">{run.error_message}</pre>
    {:else}<p class="rd-empty">No output captured.</p>{/if}
  </div>
  <div class="rd-footer">
    {#if run.token_usage}<div class="rd-tokens"><span>In: {run.token_usage.input.toLocaleString()}</span><span>Out: {run.token_usage.output.toLocaleString()}</span><span>Cost: ${(run.token_usage.cost_cents / 100).toFixed(4)}</span></div>{/if}
    {#if onRerun}<button class="rd-rerun" onclick={() => onRerun?.(run.scheduled_task_id)}>Re-run</button>{/if}
  </div>
</div>

<style>
  .rd { display: flex; flex-direction: column; background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.08); border-radius: var(--radius-md); overflow: hidden; }
  .rd-header { display: flex; align-items: center; justify-content: space-between; padding: 12px 16px; border-bottom: 1px solid rgba(255,255,255,0.05); gap: 12px; }
  .rd-left { display: flex; align-items: center; gap: 10px; min-width: 0; flex-wrap: wrap; }
  .rd-name { font-size: 0.875rem; font-weight: 600; color: var(--text-primary); }
  .rd-badge { display: inline-flex; align-items: center; gap: 5px; padding: 2px 8px; border-radius: var(--radius-full); border: 1px solid; font-size: 0.625rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; }
  .rd-pulse { width: 6px; height: 6px; border-radius: 50%; background: currentColor; animation: rd-blink 1s ease-in-out infinite; }
  @keyframes rd-blink { 0%,100% { opacity: 1; } 50% { opacity: 0.3; } }
  .rd-trigger { font-size: 0.6875rem; color: var(--text-tertiary); }
  .rd-dur { font-size: 0.6875rem; font-family: var(--font-mono); color: var(--text-tertiary); }
  .rd-close { display: flex; align-items: center; justify-content: center; width: 24px; height: 24px; border-radius: var(--radius-xs); background: none; border: none; color: var(--text-tertiary); transition: color 0.15s, background 0.15s; flex-shrink: 0; }
  .rd-close:hover { background: rgba(255,255,255,0.06); color: var(--text-secondary); }
  .rd-output { flex: 1; max-height: 400px; overflow-y: auto; scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.08) transparent; }
  .rd-stdout { margin: 0; padding: 16px; font-family: var(--font-mono); font-size: 0.75rem; line-height: 1.6; color: rgba(255,255,255,0.8); background: rgba(0,0,0,0.3); white-space: pre-wrap; word-break: break-word; }
  .rd-stdout--err { color: rgba(239,68,68,0.8); }
  .rd-empty { padding: 32px 16px; text-align: center; font-size: 0.8125rem; color: var(--text-muted); }
  .rd-footer { display: flex; align-items: center; justify-content: space-between; padding: 10px 16px; border-top: 1px solid rgba(255,255,255,0.05); gap: 12px; }
  .rd-tokens { display: flex; gap: 12px; font-size: 0.6875rem; font-family: var(--font-mono); color: var(--text-tertiary); }
  .rd-rerun { padding: 5px 14px; border-radius: var(--radius-sm); background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.12); color: var(--text-primary); font-size: 0.75rem; font-weight: 500; transition: background 0.15s, border-color 0.15s; }
  .rd-rerun:hover { background: rgba(255,255,255,0.12); border-color: rgba(255,255,255,0.2); }
</style>
