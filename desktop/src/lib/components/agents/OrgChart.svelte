<script lang="ts">
  interface HierarchyNode {
    agent_name: string;
    reports_to: string | null;
    org_role: string;
    title: string | null;
    children: HierarchyNode[];
  }

  interface Props {
    tree: HierarchyNode[];
    onMove?: (agentName: string, newReportsTo: string | null) => void;
  }

  let { tree, onMove }: Props = $props();

  // ── Constants ────────────────────────────────────────────────────────────────

  const CARD_W  = 160;
  const CARD_H  = 60;
  const H_GAP   = 24;
  const V_GAP   = 56;
  const PAD     = 32;

  // ── State ─────────────────────────────────────────────────────────────────────

  let collapsed  = $state<Set<string>>(new Set());
  let dragging   = $state<string | null>(null);
  let dropTarget = $state<string | null>(null);

  function toggleCollapse(name: string) {
    const next = new Set(collapsed);
    if (next.has(name)) {
      next.delete(name);
    } else {
      next.add(name);
    }
    collapsed = next;
  }

  // ── Role badge styles ─────────────────────────────────────────────────────────

  const ROLE_COLORS: Record<string, string> = {
    ceo:        'rgba(251,191,36,0.85)',
    director:   'rgba(59,130,246,0.85)',
    lead:       'rgba(34,197,94,0.85)',
    engineer:   'rgba(156,163,175,0.75)',
    specialist: 'rgba(168,85,247,0.85)',
  };

  function roleColor(role: string): string {
    return ROLE_COLORS[role.toLowerCase()] ?? 'rgba(156,163,175,0.75)';
  }

  // ── Layout computation ────────────────────────────────────────────────────────

  interface LayoutNode {
    node: HierarchyNode;
    x: number;
    y: number;
    isRoot: boolean;
  }

  interface Layout {
    nodes: LayoutNode[];
    edges: Array<{ x1: number; y1: number; x2: number; y2: number; key: string }>;
    svgW: number;
    svgH: number;
  }

  function subtreeWidth(node: HierarchyNode): number {
    const visible = collapsed.has(node.agent_name) ? [] : node.children;
    if (visible.length === 0) return CARD_W;
    const childrenW = visible.reduce((sum, c) => sum + subtreeWidth(c), 0)
      + (visible.length - 1) * H_GAP;
    return Math.max(CARD_W, childrenW);
  }

  function placeNodes(
    node: HierarchyNode,
    cx: number,
    cy: number,
    isRoot: boolean,
    out: LayoutNode[],
    edges: Layout['edges'],
    parentCx?: number,
    parentBottomY?: number,
  ) {
    out.push({ node, x: cx - CARD_W / 2, y: cy, isRoot });

    if (parentCx !== undefined && parentBottomY !== undefined) {
      edges.push({
        x1: parentCx, y1: parentBottomY,
        x2: cx,       y2: cy,
        key: `${node.reports_to}→${node.agent_name}`,
      });
    }

    const visible = collapsed.has(node.agent_name) ? [] : node.children;
    if (visible.length === 0) return;

    const totalW = visible.reduce((sum, c) => sum + subtreeWidth(c), 0)
      + (visible.length - 1) * H_GAP;
    let childX = cx - totalW / 2;
    const childY = cy + CARD_H + V_GAP;

    for (const child of visible) {
      const sw = subtreeWidth(child);
      placeNodes(child, childX + sw / 2, childY, false, out, edges, cx, cy + CARD_H);
      childX += sw + H_GAP;
    }
  }

  const layout = $derived.by((): Layout => {
    if (tree.length === 0) return { nodes: [], edges: [], svgW: 400, svgH: 200 };

    const allNodes: LayoutNode[] = [];
    const allEdges: Layout['edges'] = [];
    const roots = tree.filter(n => n.reports_to === null);
    let startX = PAD + CARD_W / 2;

    for (const root of roots) {
      const sw = subtreeWidth(root);
      placeNodes(root, startX + sw / 2, PAD, true, allNodes, allEdges);
      startX += sw + H_GAP;
    }

    const maxX = Math.max(...allNodes.map(n => n.x + CARD_W), 0) + PAD;
    const maxY = Math.max(...allNodes.map(n => n.y + CARD_H), 0) + PAD;

    return { nodes: allNodes, edges: allEdges, svgW: maxX, svgH: maxY };
  });

  // ── Drag handlers ─────────────────────────────────────────────────────────────

  function onDragStart(e: DragEvent, name: string) {
    dragging = name;
    e.dataTransfer?.setData('text/plain', name);
  }

  function onDragOver(e: DragEvent, name: string) {
    if (dragging === name) return;
    e.preventDefault();
    dropTarget = name;
  }

  function onDragLeave() {
    dropTarget = null;
  }

  function onDrop(e: DragEvent, targetName: string) {
    e.preventDefault();
    dropTarget = null;
    if (!dragging || dragging === targetName) { dragging = null; return; }
    onMove?.(dragging, targetName);
    dragging = null;
  }

  function onDragEnd() {
    dragging = null;
    dropTarget = null;
  }

  function truncate(s: string, max: number): string {
    return s.length > max ? s.slice(0, max) + '…' : s;
  }
</script>

<div class="orgchart" role="region" aria-label="Organization chart">
  {#if layout.nodes.length === 0}
    <div class="empty" role="status">
      <p class="empty-text">No hierarchy data</p>
    </div>
  {:else}
    <div class="canvas" style="width:{layout.svgW}px; height:{layout.svgH}px;">
      <svg
        class="edges-svg"
        width={layout.svgW}
        height={layout.svgH}
        viewBox="0 0 {layout.svgW} {layout.svgH}"
        aria-hidden="true"
      >
        <defs>
          <linearGradient id="oc-edge-grad" x1="0%" y1="0%" x2="0%" y2="100%">
            <stop offset="0%"   stop-color="rgba(255,255,255,0.14)"/>
            <stop offset="100%" stop-color="rgba(255,255,255,0.04)"/>
          </linearGradient>
        </defs>
        {#each layout.edges as e (e.key)}
          {@const cy = (e.y1 + e.y2) / 2}
          <path
            d="M {e.x1} {e.y1} C {e.x1} {cy}, {e.x2} {cy}, {e.x2} {e.y2}"
            fill="none"
            stroke="url(#oc-edge-grad)"
            stroke-width="1.5"
            stroke-linecap="round"
            class="edge"
          />
        {/each}
      </svg>

      {#each layout.nodes as nl (nl.node.agent_name)}
        {@const isDropTarget = dropTarget === nl.node.agent_name}
        {@const isDragging   = dragging   === nl.node.agent_name}
        {@const hasChildren  = nl.node.children.length > 0}
        {@const isCollapsed  = collapsed.has(nl.node.agent_name)}
        <article
          class="node"
          class:node--root={nl.isRoot}
          class:node--drop={isDropTarget}
          class:node--dragging={isDragging}
          style="left:{nl.x}px; top:{nl.y}px;"
          draggable={!nl.isRoot}
          ondragstart={(e) => onDragStart(e, nl.node.agent_name)}
          ondragover={(e) => onDragOver(e, nl.node.agent_name)}
          ondragleave={onDragLeave}
          ondrop={(e) => onDrop(e, nl.node.agent_name)}
          ondragend={onDragEnd}
          aria-label="{nl.node.agent_name} — {nl.node.org_role}"
        >
          <div class="node-top">
            <span
              class="role-badge"
              style="background:{roleColor(nl.node.org_role)};"
            >{nl.node.org_role}</span>
            <span class="node-name" title={nl.node.agent_name}>
              {truncate(nl.node.agent_name, 18)}
            </span>
            {#if hasChildren}
              <button
                class="collapse-btn"
                onclick={() => toggleCollapse(nl.node.agent_name)}
                aria-label="{isCollapsed ? 'Expand' : 'Collapse'} {nl.node.agent_name}"
                aria-expanded={!isCollapsed}
              >
                <svg width="8" height="8" viewBox="0 0 8 8" fill="none" aria-hidden="true"
                  class="chevron" class:chevron--collapsed={isCollapsed}>
                  <path d="M1.5 2.5L4 5L6.5 2.5" stroke="currentColor" stroke-width="1.5"
                    stroke-linecap="round" stroke-linejoin="round"/>
                </svg>
              </button>
            {/if}
          </div>
          {#if nl.node.title}
            <p class="node-title" title={nl.node.title}>{truncate(nl.node.title, 22)}</p>
          {/if}
        </article>
      {/each}
    </div>
  {/if}
</div>

<style>
  .orgchart {
    width: 100%;
    overflow: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255,255,255,0.08) transparent;
    border-radius: var(--radius-lg);
    background: radial-gradient(ellipse at 50% 0%, rgba(59,130,246,0.04) 0%, transparent 60%);
  }

  .canvas {
    position: relative;
    min-width: 100%;
  }

  .edges-svg {
    position: absolute;
    inset: 0;
    pointer-events: none;
  }

  .edge {
    stroke-dasharray: 400 400;
    stroke-dashoffset: 400;
    animation: edge-draw 0.45s ease forwards;
  }

  @keyframes edge-draw {
    to { stroke-dashoffset: 0; }
  }

  .node {
    position: absolute;
    width: 160px;
    min-height: 60px;
    background: rgba(255,255,255,0.04);
    backdrop-filter: blur(16px);
    -webkit-backdrop-filter: blur(16px);
    border: 1px solid rgba(255,255,255,0.09);
    border-radius: var(--radius-md);
    padding: 9px 10px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    cursor: grab;
    transition: border-color 0.15s, box-shadow 0.15s, opacity 0.15s;
    box-shadow: 0 4px 12px rgba(0,0,0,0.15), inset 0 1px 0 rgba(255,255,255,0.05);
    animation: node-in 0.28s cubic-bezier(0.34,1.56,0.64,1) both;
    user-select: none;
    z-index: 1;
  }

  .node:hover {
    z-index: 10;
    border-color: rgba(255,255,255,0.16);
    box-shadow: 0 6px 20px rgba(0,0,0,0.22), inset 0 1px 0 rgba(255,255,255,0.07);
  }

  .node--root {
    cursor: default;
    border-color: rgba(255,255,255,0.13);
    box-shadow: 0 0 0 1px rgba(255,255,255,0.06), 0 8px 24px rgba(0,0,0,0.2), inset 0 1px 0 rgba(255,255,255,0.08);
  }

  .node--drop {
    border-color: rgba(59,130,246,0.7);
    box-shadow: 0 0 0 2px rgba(59,130,246,0.25), 0 4px 16px rgba(0,0,0,0.15);
    background: rgba(59,130,246,0.08);
  }

  .node--dragging {
    opacity: 0.45;
    cursor: grabbing;
  }

  @keyframes node-in {
    from { opacity: 0; transform: scale(0.75); }
    to   { opacity: 1; transform: scale(1); }
  }

  .node-top {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
  }

  .role-badge {
    font-size: 0.5rem;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: rgba(0,0,0,0.75);
    border-radius: 999px;
    padding: 1px 5px;
    flex-shrink: 0;
    line-height: 1.6;
  }

  .node-name {
    font-size: 0.8rem;
    font-weight: 600;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
    min-width: 0;
  }

  .node-title {
    font-size: 0.6875rem;
    color: var(--text-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    line-height: 1.3;
    padding-left: 1px;
  }

  .collapse-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    flex-shrink: 0;
    background: none;
    border: 1px solid transparent;
    border-radius: var(--radius-md);
    color: rgba(255,255,255,0.3);
    padding: 0;
    transition: background 0.12s, color 0.12s, border-color 0.12s;
    cursor: pointer;
  }

  .collapse-btn:hover {
    background: rgba(255,255,255,0.07);
    border-color: rgba(255,255,255,0.08);
    color: rgba(255,255,255,0.6);
  }

  .chevron {
    transition: transform 0.2s ease;
  }

  .chevron--collapsed {
    transform: rotate(-90deg);
  }

  .empty {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 48px 24px;
  }

  .empty-text {
    font-size: 0.875rem;
    color: var(--text-tertiary);
  }
</style>
