# Knowledge Explorer (Planned)

The Knowledge Explorer is the planned frontend for `miosa_knowledge` — OSA's semantic knowledge graph. It gives developers and power users a visual and interactive interface over the SPARQL-capable triple store without touching Elixir code or a terminal.

This document describes the intended design. Implementation has not started as of March 2026.

---

## Three Views

### 1. Graph Explorer

A node-link visualization of the RDF triple store — subjects, predicates, and objects rendered as nodes and edges.

**Interactions:**
- Click a node to expand its triples
- Filter by type, predicate, or namespace prefix
- Search nodes by label or URI pattern
- Zoom, pan, and drag to rearrange the graph
- Export the visible subgraph as Turtle (`.ttl`) or JSON-LD

**Library candidates:**
- **Cytoscape.js** — battle-tested graph layout, strong performance with 10K+ nodes, good TypeScript types
- **D3 force graph** — maximum flexibility, steeper integration cost
- **Sigma.js** — WebGL-accelerated, best for graphs >50K nodes

Cytoscape.js is the recommended starting point. It handles the required layout algorithms (dagre, cola, cose-bilkent) and has a well-documented API.

**Backing endpoints:**
```
GET /api/v1/knowledge/graph?subject=<uri>&depth=2
GET /api/v1/knowledge/triples?subject=<s>&predicate=<p>&object=<o>
GET /api/v1/knowledge/context?agent_id=<id>
```

---

### 2. SPARQL Workbench

An interactive query editor for the native SPARQL engine built into `miosa_knowledge`.

**Features:**
- Syntax-highlighted SPARQL editor (Monaco Editor with a custom grammar)
- Run button with results table or JSON view
- Query history (last 50 queries, localStorage)
- Prefix autocomplete from the store's registered namespaces
- Save named queries
- Copy results as CSV or Turtle

**Supported SPARQL subset (native engine):**
- `SELECT`, `INSERT DATA`, `DELETE DATA`
- `WHERE`, `FILTER`, `OPTIONAL`
- `PREFIX` declarations
- `ORDER BY`, `DISTINCT`
- Basic Graph Pattern (BGP) joins
- Left-outer-join (`OPTIONAL`)

**Backing endpoints:**
```
POST /api/v1/knowledge/sparql
Content-Type: application/sparql-query

SELECT ?s ?p ?o WHERE { ?s ?p ?o . FILTER(?p = <urn:type>) }
```

Response format: `application/sparql-results+json` (W3C standard binding format).

---

### 3. Reasoner Dashboard

A monitoring view for the OWL 2 RL forward-chaining materializer.

**Panels:**
- Materialization status — running, idle, last run timestamp
- Inferred triple count vs asserted triple count
- Rule firing log — which rules fired, how many new triples each rule produced
- Trigger button for manual re-materialization
- Consistency check output (unsatisfiable classes, broken constraints)

**Backing endpoints:**
```
GET  /api/v1/knowledge/reasoner/status
POST /api/v1/knowledge/reasoner/run
GET  /api/v1/knowledge/reasoner/log?limit=100
```

---

## Tech Stack Considerations

### Component Framework

| Option | Rationale |
|--------|-----------|
| **Svelte 5** | Preferred for OSA frontends — minimal bundle, fine-grained reactivity, no virtual DOM overhead |
| React + Vite | Larger ecosystem, more graph library examples available |

Svelte is recommended for consistency with other OSA frontend work. The graph explorer and SPARQL workbench are predominantly view logic with little shared component state, which plays to Svelte's strengths.

### Editor

**Monaco Editor** (the VS Code engine) for the SPARQL workbench. It handles syntax highlighting, multi-cursor editing, and keyboard shortcuts that users expect from a code editor. The SPARQL grammar is available as a community extension or implementable as a custom monarch tokenizer in ~200 lines.

### State Management

- Graph view state: URL params (selected node, depth, filters) — makes views shareable
- Query history: localStorage
- Server state: SvelteKit load functions or TanStack Query for request deduplication

### Styling

Match the existing OSA HTTP dashboard — dark theme, monospace accents, minimal chrome.

---

## Connection to the Backend

The frontend communicates with the Elixir HTTP channel (`OptimalSystemAgent.Channels.HTTP`). Knowledge-specific routes live under `/api/v1/knowledge/`.

Authentication uses the same JWT bearer token scheme as all other OSA API routes. In development, authentication is disabled by default.

For live updates (new triples added by the agent, reasoner completing a run), see [WebSocket / SSE](websocket.md).

---

## See Also

- [HTTP API](http-api.md) — full API reference including knowledge endpoints
- [WebSocket / SSE](websocket.md) — real-time knowledge graph change events
- [Knowledge Graph](../backend/memory/knowledge-graph.md) — `miosa_knowledge` internals
