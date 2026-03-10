<!-- src/lib/components/agents/AgentTree.svelte -->
<!--
  Agent tree visualization — top-down hierarchy with SVG bezier connection lines.
  Layout: each wave = one horizontal level, nodes evenly spaced within each level.
  SVG renders connection lines; HTML cards overlay at absolute positions.
-->
<script lang="ts">
  import { agentsStore, type AgentTreeNode } from '$lib/stores/agents.svelte';
  import AgentNode from './AgentNode.svelte';

  interface Props {
    isCompact?: boolean;
  }

  let { isCompact = false }: Props = $props();

  // ── Expand state ─────────────────────────────────────────────────────────────

  let expandedIds = $state<Set<string>>(new Set());

  function toggleExpand(id: string) {
    const next = new Set(expandedIds);
    if (next.has(id)) {
      next.delete(id);
    } else {
      next.add(id);
    }
    expandedIds = next;
  }

  // ── Layout computation ───────────────────────────────────────────────────────

  interface NodeLayout {
    node: AgentTreeNode;
    x: number;  // center-x
    y: number;  // top-y
    w: number;
    h: number;
  }

  const layout = $derived.by((): { nodes: NodeLayout[]; svgW: number; svgH: number } => {
    // Card dimensions derived inside closure to capture isCompact reactively
    const CARD_W     = isCompact ? 36  : 168;
    const CARD_H     = isCompact ? 36  : 82;
    const CARD_H_EXP = isCompact ? 36  : 210;
    const H_GAP      = isCompact ? 20  : 28;
    const V_GAP      = isCompact ? 48  : 64;
    const PAD_X      = isCompact ? 24  : 32;
    const PAD_Y      = isCompact ? 16  : 24;

    const tree = agentsStore.agentTree;
    if (tree.length === 0) return { nodes: [], svgW: 400, svgH: 200 };

    // Group by wave
    const waves = new Map<number, AgentTreeNode[]>();
    for (const node of tree) {
      const arr = waves.get(node.wave) ?? [];
      arr.push(node);
      waves.set(node.wave, arr);
    }

    const sortedWaves = [...waves.entries()].sort(([a], [b]) => a - b);

    const nodeLayouts: NodeLayout[] = [];
    let maxWidth = 0;
    let currentY = PAD_Y;

    for (const [, waveNodes] of sortedWaves) {
      const count = waveNodes.length;
      const totalW = count * CARD_W + (count - 1) * H_GAP;
      if (totalW + PAD_X * 2 > maxWidth) maxWidth = totalW + PAD_X * 2;

      // First pass: store relative x offset (centered below)
      waveNodes.forEach((node, i) => {
        const expanded = !isCompact && expandedIds.has(node.agent.id);
        const h = expanded ? CARD_H_EXP : CARD_H;
        nodeLayouts.push({
          node,
          x: i * (CARD_W + H_GAP),
          y: currentY,
          w: CARD_W,
          h,
        });
      });

      // Max card height in this wave
      const waveH = Math.max(...waveNodes.map((n) => {
        const expanded = !isCompact && expandedIds.has(n.agent.id);
        return expanded ? CARD_H_EXP : CARD_H;
      }));
      currentY += waveH + V_GAP;
    }

    // Center each wave horizontally within maxWidth
    for (const [, waveNodes] of sortedWaves) {
      const count = waveNodes.length;
      const totalW = count * CARD_W + (count - 1) * H_GAP;
      const offsetX = PAD_X + Math.floor((maxWidth - PAD_X * 2 - totalW) / 2);
      const waveLayouts = nodeLayouts.filter((nl) =>
        waveNodes.some((n) => n.agent.id === nl.node.agent.id)
      );
      waveLayouts.forEach((nl, i) => {
        nl.x = offsetX + i * (CARD_W + H_GAP);
      });
    }

    const svgW = Math.max(maxWidth, 400);
    const svgH = currentY - V_GAP + PAD_Y;

    return { nodes: nodeLayouts, svgW, svgH };
  });

  // ── Connection paths ──────────────────────────────────────────────────────────

  interface EdgePath {
    d: string;
    key: string;
    animated: boolean;
  }

  const edges = $derived.by((): EdgePath[] => {
    const { nodes } = layout;
    const nodeMap = new Map<string, NodeLayout>();
    for (const nl of nodes) nodeMap.set(nl.node.agent.id, nl);

    const paths: EdgePath[] = [];

    for (const nl of nodes) {
      const parentId = nl.node.parentId;
      if (!parentId) continue;
      const parent = nodeMap.get(parentId);
      if (!parent) continue;

      // Parent bottom-center → child top-center
      const x1 = parent.x + parent.w / 2;
      const y1 = parent.y + parent.h;
      const x2 = nl.x + nl.w / 2;
      const y2 = nl.y;

      // Cubic bezier: control points offset vertically
      const cy = (y1 + y2) / 2;
      const d = `M ${x1} ${y1} C ${x1} ${cy}, ${x2} ${cy}, ${x2} ${y2}`;

      paths.push({
        d,
        key: `${parentId}→${nl.node.agent.id}`,
        animated: nl.node.agent.status === 'running' || nl.node.agent.status === 'queued',
      });
    }

    return paths;
  });

  // ── SVG path length for dash animation ───────────────────────────────────────
  // Using a fixed "large enough" dasharray for draw-in animation
  const DASH_LEN = 300;

  // ── Empty state ───────────────────────────────────────────────────────────────
  const isEmpty = $derived(agentsStore.agentTree.length === 0);
</script>

<div
  class="tree-container"
  class:tree-container--compact={isCompact}
  role="region"
  aria-label="Agent tree visualization"
>
  {#if isEmpty}
    <div class="tree-empty" role="status">
      <svg width="40" height="40" viewBox="0 0 40 40" fill="none" aria-hidden="true" class="tree-empty-icon">
        <circle cx="20" cy="10" r="4" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.4"/>
        <circle cx="10" cy="30" r="4" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.25"/>
        <circle cx="30" cy="30" r="4" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.25"/>
        <line x1="20" y1="14" x2="10" y2="26" stroke="currentColor" stroke-width="1" opacity="0.2"/>
        <line x1="20" y1="14" x2="30" y2="26" stroke="currentColor" stroke-width="1" opacity="0.2"/>
      </svg>
      <p class="tree-empty-text">No agent hierarchy yet</p>
      <p class="tree-empty-sub">Tree appears during multi-agent orchestration</p>
    </div>

  {:else}
    <!-- Scrollable canvas -->
    <div
      class="tree-canvas"
      style="width: {layout.svgW}px; height: {layout.svgH}px;"
    >
      <!-- SVG connection lines layer -->
      <svg
        class="tree-svg"
        width={layout.svgW}
        height={layout.svgH}
        viewBox="0 0 {layout.svgW} {layout.svgH}"
        aria-hidden="true"
      >
        <defs>
          <!-- Gradient for connection lines -->
          <linearGradient id="edge-grad-run" x1="0%" y1="0%" x2="0%" y2="100%">
            <stop offset="0%"   stop-color="rgba(34,197,94,0.5)"/>
            <stop offset="100%" stop-color="rgba(34,197,94,0.15)"/>
          </linearGradient>
          <linearGradient id="edge-grad-idle" x1="0%" y1="0%" x2="0%" y2="100%">
            <stop offset="0%"   stop-color="rgba(255,255,255,0.12)"/>
            <stop offset="100%" stop-color="rgba(255,255,255,0.04)"/>
          </linearGradient>
          <linearGradient id="edge-grad-queue" x1="0%" y1="0%" x2="0%" y2="100%">
            <stop offset="0%"   stop-color="rgba(59,130,246,0.5)"/>
            <stop offset="100%" stop-color="rgba(59,130,246,0.15)"/>
          </linearGradient>
        </defs>

        {#each edges as edge (edge.key)}
          <!-- Base path (static, slightly visible) -->
          <path
            d={edge.d}
            fill="none"
            stroke={edge.animated ? 'url(#edge-grad-run)' : 'url(#edge-grad-idle)'}
            stroke-width="1.5"
            stroke-linecap="round"
            class="edge-path"
            class:edge-path--draw={true}
          />

          <!-- Animated flow dot on active edges -->
          {#if edge.animated}
            <path
              d={edge.d}
              fill="none"
              stroke="rgba(34, 197, 94, 0.8)"
              stroke-width="2"
              stroke-linecap="round"
              stroke-dasharray="4 {DASH_LEN}"
              class="edge-flow"
            />
          {/if}
        {/each}
      </svg>

      <!-- HTML node cards layer (absolute positioned) -->
      {#each layout.nodes as nl (nl.node.agent.id)}
        <div
          class="node-wrapper"
          style="
            left: {nl.x}px;
            top:  {nl.y}px;
            width: {nl.w}px;
          "
        >
          <AgentNode
            node={nl.node}
            isRoot={nl.node.wave === 0}
            {isCompact}
            isExpanded={!isCompact && expandedIds.has(nl.node.agent.id)}
            onToggle={toggleExpand}
          />
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  /* ── Container ──────────────────────────────────────────────────────────────── */

  .tree-container {
    width: 100%;
    max-height: 480px;
    overflow: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
    position: relative;
    /* Subtle inner glow to frame the canvas */
    background:
      radial-gradient(ellipse at 50% 0%, rgba(59, 130, 246, 0.04) 0%, transparent 60%);
    border-radius: var(--radius-xl);
  }

  .tree-container--compact {
    max-height: 240px;
  }

  /* ── Canvas: the positioned surface ─────────────────────────────────────────── */

  .tree-canvas {
    position: relative;
    /* min-width so horizontal scroll works */
    min-width: 100%;
  }

  /* ── SVG layer ──────────────────────────────────────────────────────────────── */

  .tree-svg {
    position: absolute;
    inset: 0;
    pointer-events: none;
  }

  /* Edge draw-in animation — dasharray set via SVG attribute (300 = DASH_LEN) */
  .edge-path {
    stroke-dasharray: 300 300;
    stroke-dashoffset: 300;
    animation: edge-draw 0.5s ease forwards;
  }

  @keyframes edge-draw {
    to { stroke-dashoffset: 0; }
  }

  /* Flowing dot on active connections */
  .edge-flow {
    animation: edge-flow-anim 2s linear infinite;
  }

  @keyframes edge-flow-anim {
    from { stroke-dashoffset: 0; }
    to   { stroke-dashoffset: -304; }
  }

  /* ── Node wrappers ──────────────────────────────────────────────────────────── */

  .node-wrapper {
    position: absolute;
    /* Allow expanded cards to overflow without clipping siblings */
    z-index: 1;
  }

  .node-wrapper:hover {
    z-index: 10;
  }

  /* ── Empty state ────────────────────────────────────────────────────────────── */

  .tree-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 48px 24px;
    gap: 10px;
    color: var(--text-tertiary);
    text-align: center;
  }

  .tree-empty-icon {
    color: rgba(255, 255, 255, 0.1);
    margin-bottom: 4px;
  }

  .tree-empty-text {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .tree-empty-sub {
    font-size: 0.75rem;
    color: var(--text-tertiary);
    max-width: 240px;
    line-height: 1.5;
  }
</style>
