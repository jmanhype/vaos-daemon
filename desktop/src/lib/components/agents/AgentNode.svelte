<!-- src/lib/components/agents/AgentNode.svelte -->
<!-- Single agent node in the tree — compact circle or full glass card. -->
<script lang="ts">
  import type { AgentTreeNode } from '$lib/stores/agents.svelte';

  interface Props {
    node: AgentTreeNode;
    isRoot?: boolean;
    isCompact?: boolean;
    isExpanded?: boolean;
    onToggle?: (id: string) => void;
  }

  let {
    node,
    isRoot = false,
    isCompact = false,
    isExpanded = false,
    onToggle,
  }: Props = $props();

  // ── Helpers ─────────────────────────────────────────────────────────────────

  function formatTokens(tokens: number | undefined): string {
    if (tokens === undefined) return '';
    if (tokens >= 1000) return `${(tokens / 1000).toFixed(1)}k`;
    return String(tokens);
  }

  function truncate(text: string, max: number): string {
    return text.length > max ? text.slice(0, max) + '…' : text;
  }

  // Derive role label from agent name conventions (@researcher, @coder, etc.)
  function deriveRole(name: string): string {
    const lower = name.toLowerCase();
    if (lower.includes('research'))   return 'researcher';
    if (lower.includes('cod') || lower.includes('dev')) return 'coder';
    if (lower.includes('review'))     return 'reviewer';
    if (lower.includes('test'))       return 'tester';
    if (lower.includes('debug'))      return 'debugger';
    if (lower.includes('orchestrat') || lower.includes('master')) return 'orchestrator';
    if (lower.includes('architect'))  return 'architect';
    if (lower.includes('secur'))      return 'security';
    if (lower.includes('perf'))       return 'perf';
    if (lower.includes('design'))     return 'designer';
    return 'agent';
  }

  const role = $derived(deriveRole(node.agent.name));

  // Status colours
  const statusColor = $derived.by((): { bg: string; border: string; glow: string; dot: string } => {
    switch (node.agent.status) {
      case 'running': return {
        bg:     'rgba(34, 197, 94, 0.08)',
        border: 'rgba(34, 197, 94, 0.25)',
        glow:   'rgba(34, 197, 94, 0.4)',
        dot:    '#22c55e',
      };
      case 'queued': return {
        bg:     'rgba(59, 130, 246, 0.08)',
        border: 'rgba(59, 130, 246, 0.25)',
        glow:   'rgba(59, 130, 246, 0.4)',
        dot:    '#3b82f6',
      };
      case 'error': return {
        bg:     'rgba(239, 68, 68, 0.08)',
        border: 'rgba(239, 68, 68, 0.25)',
        glow:   'rgba(239, 68, 68, 0.4)',
        dot:    '#ef4444',
      };
      case 'done': return {
        bg:     'rgba(255, 255, 255, 0.04)',
        border: 'rgba(255, 255, 255, 0.08)',
        glow:   'transparent',
        dot:    'rgba(255,255,255,0.3)',
      };
      default: return {
        bg:     'rgba(255, 255, 255, 0.03)',
        border: 'rgba(255, 255, 255, 0.07)',
        glow:   'transparent',
        dot:    'rgba(255,255,255,0.2)',
      };
    }
  });

  const isPulsing = $derived(node.agent.status === 'running' || node.agent.status === 'queued');

  // Tooltip text for compact mode
  const tooltip = $derived(`${node.agent.name} · ${node.agent.status}${node.agent.task ? ' · ' + node.agent.task : ''}`);
</script>

{#if isCompact}
  <!-- ── Compact: circle only with tooltip ──────────────────────────────────── -->
  <button
    class="compact-node"
    class:compact-node--root={isRoot}
    class:compact-node--pulsing={isPulsing}
    style="
      --dot-color: {statusColor.dot};
      --glow-color: {statusColor.glow};
    "
    onclick={() => onToggle?.(node.agent.id)}
    aria-label={tooltip}
    title={tooltip}
  >
    <span class="compact-dot" aria-hidden="true"></span>
    {#if isRoot}
      <span class="compact-root-ring" aria-hidden="true"></span>
    {/if}
  </button>

{:else}
  <!-- ── Full: glass card ────────────────────────────────────────────────────── -->
  <article
    class="agent-node"
    class:agent-node--root={isRoot}
    class:agent-node--expanded={isExpanded}
    class:agent-node--pulsing={isPulsing}
    class:agent-node--done={node.agent.status === 'done'}
    style="
      --node-bg:     {statusColor.bg};
      --node-border: {statusColor.border};
      --node-glow:   {statusColor.glow};
      --dot-color:   {statusColor.dot};
    "
  >
    <!-- Card top row -->
    <div class="node-header">
      <div class="node-header-left">
        <!-- Status dot -->
        <span
          class="node-dot"
          class:node-dot--pulsing={isPulsing}
          aria-hidden="true"
        ></span>

        <div class="node-identity">
          <span class="node-name" title={node.agent.name}>
            {truncate(node.agent.name.replace(/^@/, ''), 18)}
          </span>
          <span class="node-role">{role}</span>
        </div>
      </div>

      <!-- Token badge -->
      {#if node.agent.tokens}
        <span class="token-badge" aria-label="{formatTokens(node.agent.tokens)} tokens">
          {formatTokens(node.agent.tokens)}
        </span>
      {/if}

      <!-- Expand toggle -->
      <button
        class="node-expand-btn"
        onclick={() => onToggle?.(node.agent.id)}
        aria-label="{isExpanded ? 'Collapse' : 'Expand'} {node.agent.name} details"
        aria-expanded={isExpanded}
      >
        <svg
          width="10"
          height="10"
          viewBox="0 0 10 10"
          fill="none"
          aria-hidden="true"
          class="expand-chevron"
          class:expand-chevron--open={isExpanded}
        >
          <path d="M2.5 3.5L5 6L7.5 3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
      </button>
    </div>

    <!-- Current action (collapsed) -->
    {#if !isExpanded && node.agent.task}
      <p class="node-action" title={node.agent.task}>
        {truncate(node.agent.task, 36)}
      </p>
    {/if}

    <!-- Progress bar -->
    {#if (node.agent.status === 'running' || node.agent.status === 'queued') && node.agent.progress > 0}
      <div
        class="node-progress"
        role="progressbar"
        aria-valuenow={node.agent.progress}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-label="Progress"
      >
        <div class="node-progress-fill" style="width: {node.agent.progress}%"></div>
      </div>
    {/if}

    <!-- Expanded details -->
    {#if isExpanded}
      <div class="node-detail">
        <div class="detail-divider" aria-hidden="true"></div>

        {#if node.agent.task}
          <div class="detail-row">
            <span class="detail-label">Task</span>
            <span class="detail-value">{node.agent.task}</span>
          </div>
        {/if}

        {#if node.agent.error}
          <div class="detail-row detail-row--error">
            <span class="detail-label">Error</span>
            <pre class="detail-error">{node.agent.error}</pre>
          </div>
        {/if}

        <div class="detail-metrics">
          {#if node.agent.duration !== undefined}
            <div class="detail-metric">
              <span class="detail-metric-label">Duration</span>
              <span class="detail-metric-value">
                {node.agent.duration < 60
                  ? `${Math.round(node.agent.duration)}s`
                  : `${Math.floor(node.agent.duration / 60)}m ${Math.round(node.agent.duration % 60)}s`}
              </span>
            </div>
          {/if}
          {#if node.agent.tokens !== undefined}
            <div class="detail-metric">
              <span class="detail-metric-label">Tokens</span>
              <span class="detail-metric-value">{formatTokens(node.agent.tokens)}</span>
            </div>
          {/if}
          <div class="detail-metric">
            <span class="detail-metric-label">Wave</span>
            <span class="detail-metric-value">{node.wave}</span>
          </div>
        </div>

        <code class="detail-id" aria-label="Agent ID">{node.agent.id}</code>
      </div>
    {/if}
  </article>
{/if}

<style>
  /* ── Compact node ───────────────────────────────────────────────────────────── */

  .compact-node {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 36px;
    height: 36px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.06);
    border: 1.5px solid var(--dot-color, rgba(255, 255, 255, 0.15));
    cursor: pointer;
    transition: transform 0.15s, box-shadow 0.15s;
    flex-shrink: 0;
  }

  .compact-node--root {
    width: 44px;
    height: 44px;
  }

  .compact-node:hover {
    transform: scale(1.12);
    box-shadow: 0 0 12px var(--glow-color, transparent);
  }

  .compact-node--pulsing {
    animation: compact-pulse 2.4s ease-in-out infinite;
  }

  .compact-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    background: var(--dot-color, rgba(255, 255, 255, 0.3));
    box-shadow: 0 0 6px var(--dot-color, transparent);
    flex-shrink: 0;
  }

  .compact-node--root .compact-dot {
    width: 14px;
    height: 14px;
  }

  .compact-root-ring {
    position: absolute;
    inset: -4px;
    border-radius: 50%;
    border: 1px solid rgba(255, 255, 255, 0.08);
    pointer-events: none;
  }

  @keyframes compact-pulse {
    0%, 100% { box-shadow: 0 0 0 0 var(--glow-color); }
    50%       { box-shadow: 0 0 0 5px transparent; }
  }

  /* ── Full card ──────────────────────────────────────────────────────────────── */

  .agent-node {
    width: 168px;
    background: var(--node-bg);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid var(--node-border);
    border-radius: var(--radius-lg);
    padding: 10px 11px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    cursor: default;
    transition:
      width 0.25s ease,
      box-shadow 0.2s ease,
      border-color 0.2s ease;
    /* Mount animation */
    animation: node-mount 0.3s cubic-bezier(0.34, 1.56, 0.64, 1) both;
    box-shadow:
      0 4px 16px rgba(0, 0, 0, 0.12),
      inset 0 1px 0 rgba(255, 255, 255, 0.06);
  }

  .agent-node--root {
    width: 180px;
    border-width: 1.5px;
    box-shadow:
      0 0 0 1px var(--node-border),
      0 8px 24px rgba(0, 0, 0, 0.2),
      inset 0 1px 0 rgba(255, 255, 255, 0.1);
  }

  .agent-node--expanded {
    width: 220px;
  }

  .agent-node--done {
    opacity: 0.65;
  }

  .agent-node--pulsing {
    box-shadow:
      0 0 0 1px var(--node-border),
      0 4px 16px rgba(0, 0, 0, 0.12),
      0 0 20px var(--node-glow),
      inset 0 1px 0 rgba(255, 255, 255, 0.08);
  }

  @keyframes node-mount {
    from { opacity: 0; transform: scale(0.7); }
    to   { opacity: 1; transform: scale(1); }
  }

  /* ── Header ─────────────────────────────────────────────────────────────────── */

  .node-header {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
  }

  .node-header-left {
    display: flex;
    align-items: center;
    gap: 7px;
    flex: 1;
    min-width: 0;
  }

  /* ── Status dot ─────────────────────────────────────────────────────────────── */

  .node-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--dot-color);
    box-shadow: 0 0 5px var(--dot-color);
    flex-shrink: 0;
  }

  .node-dot--pulsing {
    animation: dot-glow 2s ease-in-out infinite;
  }

  @keyframes dot-glow {
    0%, 100% { box-shadow: 0 0 4px var(--dot-color); }
    50%       { box-shadow: 0 0 10px var(--dot-color), 0 0 20px var(--node-glow); }
  }

  /* ── Identity ───────────────────────────────────────────────────────────────── */

  .node-identity {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
    flex: 1;
  }

  .node-name {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary);
    line-height: 1.2;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .node-role {
    font-size: 0.625rem;
    font-weight: 600;
    letter-spacing: 0.07em;
    text-transform: uppercase;
    color: var(--text-muted);
    line-height: 1;
  }

  /* ── Token badge ─────────────────────────────────────────────────────────────── */

  .token-badge {
    font-size: 0.5625rem;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-full);
    padding: 1px 5px;
    flex-shrink: 0;
    letter-spacing: 0.02em;
  }

  /* ── Expand button ──────────────────────────────────────────────────────────── */

  .node-expand-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    border-radius: var(--radius-xs);
    background: none;
    border: 1px solid transparent;
    color: rgba(255, 255, 255, 0.3);
    flex-shrink: 0;
    transition: all 0.15s;
    padding: 0;
  }

  .node-expand-btn:hover {
    background: rgba(255, 255, 255, 0.06);
    color: rgba(255, 255, 255, 0.6);
    border-color: rgba(255, 255, 255, 0.08);
  }

  .expand-chevron {
    transition: transform 0.2s ease;
  }

  .expand-chevron--open {
    transform: rotate(180deg);
  }

  /* ── Current action ─────────────────────────────────────────────────────────── */

  .node-action {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    line-height: 1.4;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    padding-left: 14px; /* indent under dot */
  }

  /* ── Progress bar ───────────────────────────────────────────────────────────── */

  .node-progress {
    height: 2px;
    background: rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    overflow: hidden;
  }

  .node-progress-fill {
    height: 100%;
    background: var(--dot-color);
    border-radius: var(--radius-full);
    transition: width 0.4s ease;
    opacity: 0.75;
  }

  /* ── Expanded detail ────────────────────────────────────────────────────────── */

  .node-detail {
    display: flex;
    flex-direction: column;
    gap: 8px;
    animation: detail-in 0.2s ease both;
  }

  @keyframes detail-in {
    from { opacity: 0; transform: translateY(-4px); }
    to   { opacity: 1; transform: translateY(0); }
  }

  .detail-divider {
    height: 1px;
    background: linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.07), transparent);
  }

  .detail-row {
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  :global(.detail-row--error) .detail-value {
    color: rgba(239, 68, 68, 0.8);
  }

  .detail-label {
    font-size: 0.5625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: rgba(255, 255, 255, 0.2);
  }

  .detail-value {
    font-size: 0.6875rem;
    color: var(--text-secondary);
    line-height: 1.4;
    word-break: break-word;
  }

  .detail-error {
    font-family: var(--font-mono);
    font-size: 0.625rem;
    color: rgba(239, 68, 68, 0.8);
    background: rgba(239, 68, 68, 0.06);
    border: 1px solid rgba(239, 68, 68, 0.1);
    border-radius: var(--radius-xs);
    padding: 5px 7px;
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 80px;
    overflow-y: auto;
    margin: 0;
  }

  .detail-metrics {
    display: flex;
    gap: 8px;
  }

  .detail-metric {
    display: flex;
    flex-direction: column;
    gap: 1px;
  }

  .detail-metric-label {
    font-size: 0.5rem;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: rgba(255, 255, 255, 0.2);
  }

  .detail-metric-value {
    font-size: 0.6875rem;
    font-weight: 500;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
  }

  .detail-id {
    font-family: var(--font-mono);
    font-size: 0.5625rem;
    color: var(--text-muted);
    word-break: break-all;
    line-height: 1.5;
    user-select: text;
  }
</style>
