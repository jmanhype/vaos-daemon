<script lang="ts">
  import { onMount } from 'svelte';
  import { fly, fade } from 'svelte/transition';


  // ── Types ───────────────────────────────────────────────────────────────────

  type ConnectorType = 'repo' | 'server' | 'app' | 'custom';
  type ConnectorStatus = 'connected' | 'disconnected' | 'error';

  interface Connector {
    id: string;
    name: string;
    type: ConnectorType;
    status: ConnectorStatus;
    url: string;
    description: string;
    lastSeen: string | null;
  }

  // ── State ───────────────────────────────────────────────────────────────────

  let connectors = $state<Connector[]>([]);
  let detectedServices = $state<DetectedService[]>([]);
  let scanning = $state(false);
  let showAddModal = $state(false);

  // Add form
  let addName = $state('');
  let addType = $state<ConnectorType>('repo');
  let addUrl = $state('');
  let addDescription = $state('');

  interface DetectedService {
    name: string;
    port: number;
    type: ConnectorType;
    url: string;
  }

  // Common local services to scan
  const KNOWN_PORTS: { port: number; name: string; type: ConnectorType }[] = [
    { port: 3000, name: 'Dev Server (3000)', type: 'server' },
    { port: 3001, name: 'Dev Server (3001)', type: 'server' },
    { port: 4000, name: 'Phoenix (4000)', type: 'server' },
    { port: 5173, name: 'Vite (5173)', type: 'server' },
    { port: 5199, name: 'OSA Frontend (5199)', type: 'app' },
    { port: 8000, name: 'Python Server (8000)', type: 'server' },
    { port: 8080, name: 'HTTP Server (8080)', type: 'server' },
    { port: 8888, name: 'Jupyter (8888)', type: 'app' },
    { port: 9089, name: 'OSA Backend (9089)', type: 'app' },
    { port: 11434, name: 'Ollama (11434)', type: 'app' },
    { port: 5432, name: 'PostgreSQL (5432)', type: 'server' },
    { port: 6379, name: 'Redis (6379)', type: 'server' },
    { port: 27017, name: 'MongoDB (27017)', type: 'server' },
  ];

  const STORAGE_KEY = 'osa-connectors';

  onMount(() => {
    // Load saved connectors
    try {
      const stored = localStorage.getItem(STORAGE_KEY);
      if (stored) connectors = JSON.parse(stored);
    } catch { /* */ }

    // Auto-scan on load
    scanServices();
  });

  function saveConnectors() {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(connectors));
  }

  async function scanServices() {
    scanning = true;
    detectedServices = [];

    const results: DetectedService[] = [];

    // Check each known port with a quick fetch
    const checks = KNOWN_PORTS.map(async ({ port, name, type }) => {
      try {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 1500);
        await fetch(`http://127.0.0.1:${port}`, {
          mode: 'no-cors',
          signal: controller.signal,
        });
        clearTimeout(timeout);
        results.push({ name, port, type, url: `http://127.0.0.1:${port}` });
      } catch {
        // Port not responding — skip
      }
    });

    await Promise.allSettled(checks);
    detectedServices = results.sort((a, b) => a.port - b.port);
    scanning = false;
  }

  function addConnector() {
    if (!addName.trim() || !addUrl.trim()) return;

    const connector: Connector = {
      id: `${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
      name: addName.trim(),
      type: addType,
      status: 'disconnected',
      url: addUrl.trim(),
      description: addDescription.trim(),
      lastSeen: null,
    };

    connectors = [...connectors, connector];
    saveConnectors();
    showAddModal = false;
    addName = '';
    addUrl = '';
    addDescription = '';
  }

  function addFromDetected(service: DetectedService) {
    // Check if already added
    if (connectors.some(c => c.url === service.url)) return;

    const connector: Connector = {
      id: `${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
      name: service.name,
      type: service.type,
      status: 'connected',
      url: service.url,
      description: `Auto-detected on port ${service.port}`,
      lastSeen: new Date().toISOString(),
    };

    connectors = [...connectors, connector];
    saveConnectors();
  }

  function removeConnector(id: string) {
    connectors = connectors.filter(c => c.id !== id);
    saveConnectors();
  }

  async function connectToOSA(connector: Connector) {
    // Send a message to OSA to connect/analyze this service
    const message = `Connect to the service "${connector.name}" at ${connector.url}. Analyze its API, understand its structure, and tell me how to integrate with it.`;

    // Dispatch to chat via custom event
    if (typeof window !== 'undefined') {
      window.dispatchEvent(new CustomEvent('osa:send-message', { detail: { message } }));
    }
  }

  function typeIcon(type: ConnectorType): string {
    switch (type) {
      case 'repo': return 'M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253';
      case 'server': return 'M5.25 14.5h13.5m-13.5 0a3 3 0 01-3-3m3 3a3 3 0 100 6h13.5a3 3 0 100-6m-16.5-3a3 3 0 013-3h13.5a3 3 0 013 3m-19.5 0a4.5 4.5 0 01.9-2.7L5.737 5.1a3.375 3.375 0 012.7-1.35h7.126c1.062 0 2.062.5 2.7 1.35l2.587 3.45a4.5 4.5 0 01.9 2.7m0 0h.375a2.625 2.625 0 010 5.25H17.25';
      case 'app': return 'M9 17.25v1.007a3 3 0 01-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0115 18.257V17.25m6-12V15a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 15V5.25m18 0A2.25 2.25 0 0018.75 3H5.25A2.25 2.25 0 003 5.25m18 0V12a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 12V5.25';
      case 'custom': return 'M11.42 15.17l-5.1-5.1m0 0L11.42 5m-5.1 5.07h13.56';
    }
  }

  const statusColor: Record<ConnectorStatus, string> = {
    connected: 'rgba(34, 197, 94, 0.8)',
    disconnected: 'rgba(255, 255, 255, 0.25)',
    error: 'rgba(239, 68, 68, 0.8)',
  };
</script>

<div class="connectors-page">
  <!-- Header -->
  <header class="page-header">
    <div class="header-text">
      <h1 class="page-title">OS Connectors</h1>
      <p class="page-subtitle">Connect OSA to your local services, repos, and applications.</p>
    </div>
    <div class="header-actions">
      <button
        class="btn-ghost"
        onclick={scanServices}
        disabled={scanning}
        aria-label="Scan for services"
      >
        {#if scanning}
          <span class="spinner" aria-hidden="true"></span>
          Scanning...
        {:else}
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
          Scan
        {/if}
      </button>
      <button
        class="btn-primary"
        onclick={() => { showAddModal = true; }}
        aria-label="Add connector"
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
        Add
      </button>
    </div>
  </header>

  <!-- Detected services -->
  {#if detectedServices.length > 0}
    <section class="section" transition:fly={{ y: 12, duration: 200 }}>
      <h2 class="section-title">Detected Services</h2>
      <p class="section-desc">Services running on your machine right now.</p>
      <div class="service-grid">
        {#each detectedServices as service (service.port)}
          {@const alreadyAdded = connectors.some(c => c.url === service.url)}
          <div class="service-card">
            <div class="service-info">
              <svg class="service-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <path d={typeIcon(service.type)} />
              </svg>
              <div>
                <div class="service-name">{service.name}</div>
                <div class="service-url">{service.url}</div>
              </div>
            </div>
            <button
              class="btn-sm"
              class:btn-sm--added={alreadyAdded}
              onclick={() => addFromDetected(service)}
              disabled={alreadyAdded}
            >
              {alreadyAdded ? 'Added' : 'Add'}
            </button>
          </div>
        {/each}
      </div>
    </section>
  {/if}

  <!-- Connected services -->
  <section class="section">
    <h2 class="section-title">Connected</h2>
    {#if connectors.length === 0}
      <div class="empty-state">
        <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M13.19 8.688a4.5 4.5 0 011.242 7.244l-4.5 4.5a4.5 4.5 0 01-6.364-6.364l1.757-1.757m9.86-2.556a4.5 4.5 0 00-6.364-6.364L4.5 8.25l4.5 4.5 4.19-4.062z"/>
        </svg>
        <p>No connectors yet. Scan for services or add one manually.</p>
      </div>
    {:else}
      <div class="connector-list">
        {#each connectors as connector (connector.id)}
          <div class="connector-row" transition:fly={{ y: 8, duration: 150 }}>
            <div class="connector-status-dot" style:background={statusColor[connector.status]}></div>
            <svg class="connector-type-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <path d={typeIcon(connector.type)} />
            </svg>
            <div class="connector-info">
              <div class="connector-name">{connector.name}</div>
              <div class="connector-url">{connector.url}</div>
            </div>
            <div class="connector-actions">
              <button
                class="btn-ghost btn-sm"
                onclick={() => connectToOSA(connector)}
                title="Have OSA connect and analyze"
                aria-label="Connect OSA to {connector.name}"
              >
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>
                Connect
              </button>
              <button
                class="btn-ghost btn-sm btn-danger"
                onclick={() => removeConnector(connector.id)}
                aria-label="Remove {connector.name}"
              >
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
              </button>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </section>
</div>

<!-- Add connector modal -->
{#if showAddModal}
  <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
  <div class="modal-backdrop" onclick={() => { showAddModal = false; }} transition:fade={{ duration: 150 }}>
    <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
    <div class="modal-card" onclick={(e) => e.stopPropagation()} transition:fly={{ y: -10, duration: 150 }}>
      <h3 class="modal-title">Add Connector</h3>

      <div class="modal-field">
        <label class="modal-label" for="conn-name">Name</label>
        <input id="conn-name" class="field-input" bind:value={addName} placeholder="My API Server" autocomplete="off" />
      </div>

      <div class="modal-field">
        <label class="modal-label" for="conn-type">Type</label>
        <select id="conn-type" class="field-select" bind:value={addType}>
          <option value="repo">Repository</option>
          <option value="server">Server / API</option>
          <option value="app">Application</option>
          <option value="custom">Custom</option>
        </select>
      </div>

      <div class="modal-field">
        <label class="modal-label" for="conn-url">URL / Path</label>
        <input id="conn-url" class="field-input" bind:value={addUrl} placeholder="http://localhost:3000 or /path/to/repo" autocomplete="off" />
      </div>

      <div class="modal-field">
        <label class="modal-label" for="conn-desc">Description (optional)</label>
        <input id="conn-desc" class="field-input" bind:value={addDescription} placeholder="What this service does" autocomplete="off" />
      </div>

      <div class="modal-actions">
        <button class="btn-ghost" onclick={() => { showAddModal = false; }}>Cancel</button>
        <button class="btn-primary" onclick={addConnector} disabled={!addName.trim() || !addUrl.trim()}>Add</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .connectors-page {
    height: 100%;
    overflow-y: auto;
    padding: 32px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .page-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    margin-bottom: 28px;
  }

  .page-title {
    font-size: 1.5rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.02em;
  }

  .page-subtitle {
    font-size: 0.875rem;
    color: var(--text-tertiary);
    margin-top: 4px;
  }

  .header-actions {
    display: flex;
    gap: 8px;
  }

  /* Section */
  .section {
    margin-bottom: 28px;
  }

  .section-title {
    font-size: 0.8125rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-tertiary);
    margin-bottom: 6px;
  }

  .section-desc {
    font-size: 0.8125rem;
    color: var(--text-muted);
    margin-bottom: 14px;
  }

  /* Detected services grid */
  .service-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
    gap: 8px;
  }

  .service-card {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 14px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid var(--border-default);
    border-radius: 10px;
    transition: background 0.12s;
  }

  .service-card:hover {
    background: rgba(255, 255, 255, 0.06);
  }

  .service-info {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .service-icon {
    color: var(--text-tertiary);
    flex-shrink: 0;
  }

  .service-name {
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-primary);
  }

  .service-url {
    font-size: 0.6875rem;
    font-family: var(--font-mono);
    color: var(--text-muted);
  }

  /* Connector list */
  .connector-list {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .connector-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 14px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid var(--border-default);
    border-radius: 10px;
    transition: background 0.12s;
  }

  .connector-row:hover {
    background: rgba(255, 255, 255, 0.05);
  }

  .connector-status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .connector-type-icon {
    color: var(--text-tertiary);
    flex-shrink: 0;
  }

  .connector-info {
    flex: 1;
    min-width: 0;
  }

  .connector-name {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--text-primary);
  }

  .connector-url {
    font-size: 0.75rem;
    font-family: var(--font-mono);
    color: var(--text-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .connector-actions {
    display: flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
  }

  /* Buttons */
  .btn-primary {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 7px 14px;
    background: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.15);
    border-radius: 9999px;
    color: var(--text-primary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.12s, border-color 0.12s;
  }

  .btn-primary:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.15);
    border-color: rgba(255, 255, 255, 0.25);
  }

  .btn-primary:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .btn-ghost {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 7px 14px;
    background: transparent;
    border: 1px solid var(--border-default);
    border-radius: 9999px;
    color: var(--text-secondary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.12s, border-color 0.12s;
  }

  .btn-ghost:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.05);
    border-color: var(--border-hover);
  }

  .btn-ghost:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .btn-sm {
    padding: 4px 10px;
    font-size: 0.75rem;
    border-radius: 9999px;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid var(--border-default);
    color: var(--text-secondary);
    cursor: pointer;
    transition: background 0.12s;
  }

  .btn-sm:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.12);
  }

  .btn-sm--added {
    color: rgba(34, 197, 94, 0.7);
    border-color: rgba(34, 197, 94, 0.2);
  }

  .btn-sm:disabled {
    cursor: default;
  }

  .btn-danger:hover {
    color: rgba(239, 68, 68, 0.8);
    border-color: rgba(239, 68, 68, 0.3);
  }

  .spinner {
    width: 14px;
    height: 14px;
    border: 2px solid rgba(255, 255, 255, 0.15);
    border-top-color: rgba(255, 255, 255, 0.6);
    border-radius: 50%;
    animation: spin 0.6s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  /* Empty state */
  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
    padding: 40px;
    color: var(--text-muted);
    text-align: center;
    font-size: 0.875rem;
  }

  /* Modal */
  .modal-backdrop {
    position: fixed;
    inset: 0;
    z-index: var(--z-modal-backdrop);
    background: rgba(0, 0, 0, 0.6);
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .modal-card {
    z-index: var(--z-modal);
    width: min(440px, calc(100vw - 32px));
    background: rgba(20, 20, 22, 0.95);
    backdrop-filter: blur(40px);
    -webkit-backdrop-filter: blur(40px);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 16px;
    padding: 24px;
    box-shadow: 0 24px 64px rgba(0, 0, 0, 0.6);
  }

  .modal-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 20px;
  }

  .modal-field {
    margin-bottom: 14px;
  }

  .modal-label {
    display: block;
    font-size: 0.8125rem;
    font-weight: 500;
    color: var(--text-secondary);
    margin-bottom: 4px;
  }

  .field-input {
    width: 100%;
    padding: 8px 12px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid var(--border-default);
    border-radius: 8px;
    color: var(--text-primary);
    font-size: 0.875rem;
    outline: none;
    transition: border-color 0.15s;
  }

  .field-input:focus {
    border-color: var(--border-focus);
  }

  .field-input::placeholder {
    color: var(--text-muted);
  }

  .field-select {
    width: 100%;
    padding: 8px 12px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid var(--border-default);
    border-radius: 8px;
    color: var(--text-primary);
    font-size: 0.875rem;
    outline: none;
  }

  .modal-actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 20px;
  }
</style>
