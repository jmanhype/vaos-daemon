<script lang="ts">
  import { onMount } from 'svelte';
  import { invoke } from '@tauri-apps/api/core';
  import { open as openDialog } from '@tauri-apps/plugin-dialog';
  import { openUrl } from '@tauri-apps/plugin-opener';
  import { getVersion } from '@tauri-apps/api/app';
  import { health, providers, settings } from '$lib/api/client';
  import { permissionStore } from '$lib/stores/permissions.svelte';
  import { PROVIDERS } from '$lib/onboarding/types';
  import type { Provider, Settings, HealthResponse } from '$lib/api/types';

  // ── Tab definitions ──────────────────────────────────────────────────────────

  type TabId = 'general' | 'provider' | 'permissions' | 'advanced' | 'about';

  interface Tab {
    id: TabId;
    label: string;
    icon: string;
  }

  const TABS: Tab[] = [
    { id: 'general',     label: 'General',     icon: 'sliders' },
    { id: 'provider',    label: 'Provider',     icon: 'cpu' },
    { id: 'permissions', label: 'Permissions',  icon: 'shield' },
    { id: 'advanced',    label: 'Advanced',     icon: 'terminal' },
    { id: 'about',       label: 'About',        icon: 'info' },
  ];

  // ── State ────────────────────────────────────────────────────────────────────

  let activeTab = $state<TabId>('general');
  let saving = $state(false);
  let saveSuccess = $state(false);

  // General
  let agentName     = $state('OSA Agent');
  let workingDir    = $state('');
  let theme         = $state<'dark'>('dark');

  // Provider
  let connectedProviders = $state<Provider[]>([]);
  let selectedProvider   = $state('');
  let apiKey             = $state('');
  let showApiKey         = $state(false);
  let testingConnection  = $state(false);
  let connectionStatus   = $state<'idle' | 'ok' | 'error'>('idle');
  let connectionMessage  = $state('');

  // Permissions
  let yoloMode      = $state(permissionStore.yolo);
  let alwaysAllowed = $state<string[]>([]);
  let permTier      = $state<'full' | 'workspace' | 'readonly'>('full');

  // Advanced
  let backendUrl  = $state('http://127.0.0.1:8089');
  let logLevel    = $state<'error' | 'warn' | 'info' | 'debug'>('info');
  let doctorOutput = $state('');
  let runningDoctor = $state(false);
  let restartingBackend = $state(false);
  let contextWindow = $state<number | null>(null);

  // About
  let appVersion     = $state('');
  let backendVersion = $state('');
  let healthData     = $state<HealthResponse | null>(null);

  // ── Init ─────────────────────────────────────────────────────────────────────

  onMount(async () => {
    await Promise.allSettled([
      loadSettings(),
      loadProviders(),
      loadAppVersion(),
      loadBackendHealth(),
    ]);
  });

  async function loadSettings() {
    try {
      const s: Settings = await settings.get();
      selectedProvider = s.provider ?? '';
      workingDir       = s.working_dir ?? '';
      theme            = 'dark';
    } catch {
      // backend may be offline — fail silently
    }
  }

  async function loadProviders() {
    try {
      connectedProviders = await providers.list();
    } catch {
      connectedProviders = [];
    }
  }

  async function loadAppVersion() {
    try {
      appVersion = await getVersion();
    } catch {
      appVersion = '—';
    }
  }

  async function loadBackendHealth() {
    try {
      healthData     = await health.get();
      backendVersion = healthData?.version ?? '—';
      contextWindow  = null; // no field in HealthResponse
    } catch {
      backendVersion = 'offline';
    }
  }

  // ── General actions ──────────────────────────────────────────────────────────

  async function pickWorkingDir() {
    try {
      const selected = await openDialog({ directory: true, multiple: false });
      if (typeof selected === 'string') workingDir = selected;
    } catch {
      // dialog unavailable outside Tauri
    }
  }

  // ── Provider actions ─────────────────────────────────────────────────────────

  async function testConnection() {
    if (!selectedProvider || !apiKey.trim()) return;
    testingConnection = true;
    connectionStatus  = 'idle';
    connectionMessage = '';
    try {
      await providers.connect(selectedProvider, apiKey.trim());
      connectionStatus  = 'ok';
      connectionMessage = 'Connection successful.';
      await loadProviders();
    } catch (err) {
      connectionStatus  = 'error';
      connectionMessage = err instanceof Error ? err.message : 'Connection failed.';
    } finally {
      testingConnection = false;
    }
  }

  // ── Permissions actions ──────────────────────────────────────────────────────

  function toggleYolo() {
    yoloMode = !yoloMode;
    if (yoloMode) {
      permissionStore.enableYolo();
    } else {
      permissionStore.disableYolo();
    }
  }

  function removeAlwaysAllowed(tool: string) {
    alwaysAllowed = alwaysAllowed.filter((t) => t !== tool);
  }

  // ── Advanced actions ─────────────────────────────────────────────────────────

  async function restartBackend() {
    restartingBackend = true;
    try {
      await invoke('restart_backend');
    } catch {
      // command may not exist in dev — ignore
    } finally {
      restartingBackend = false;
    }
  }

  async function runDoctor() {
    runningDoctor = true;
    doctorOutput  = '';
    try {
      const h = await health.get();
      doctorOutput =
        `Status:  ${h.status}\n` +
        `Version: ${h.version}\n` +
        `Provider: ${h.provider ?? 'none'}\n` +
        `Agents active: ${h.agents_active}\n` +
        `Uptime: ${Math.floor(h.uptime_seconds / 60)}m ${h.uptime_seconds % 60}s`;
    } catch (err) {
      doctorOutput = `Backend unreachable.\n${err instanceof Error ? err.message : String(err)}`;
    } finally {
      runningDoctor = false;
    }
  }

  // ── Save ─────────────────────────────────────────────────────────────────────

  async function saveSettings() {
    saving = true;
    saveSuccess = false;
    try {
      await settings.update({
        working_dir: workingDir,
        theme,
      });
      saveSuccess = true;
      setTimeout(() => { saveSuccess = false; }, 2000);
    } catch {
      // surface nothing — status indicator handles it
    } finally {
      saving = false;
    }
  }

  // ── About links ──────────────────────────────────────────────────────────────

  async function openLink(url: string) {
    try {
      await openUrl(url);
    } catch {
      window.open(url, '_blank');
    }
  }
</script>

<!-- ─────────────────────────────────────────────────────────────────────────── -->
<!-- Layout                                                                      -->
<!-- ─────────────────────────────────────────────────────────────────────────── -->

<div class="settings-root">
  <!-- Left tab rail -->
  <nav class="tab-rail" aria-label="Settings sections">
    <div class="rail-header">
      <span class="rail-title">Settings</span>
    </div>

    <ul class="rail-list" role="tablist">
      {#each TABS as tab (tab.id)}
        <li role="none">
          <button
            role="tab"
            aria-selected={activeTab === tab.id}
            aria-controls="settings-panel"
            class="rail-item"
            class:rail-item--active={activeTab === tab.id}
            onclick={() => { activeTab = tab.id; }}
          >
            <span class="rail-icon" aria-hidden="true">
              {#if tab.icon === 'sliders'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M10.5 6h9.75M10.5 6a1.5 1.5 0 11-3 0m3 0a1.5 1.5 0 10-3 0M3.75 6H7.5m3 12h9.75m-9.75 0a1.5 1.5 0 01-3 0m3 0a1.5 1.5 0 00-3 0m-3.75 0H7.5m9-6h3.75m-3.75 0a1.5 1.5 0 01-3 0m3 0a1.5 1.5 0 00-3 0m-9.75 0h9.75"/></svg>
              {:else if tab.icon === 'cpu'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M8.25 3v1.5M4.5 8.25H3m18 0h-1.5M4.5 12H3m18 0h-1.5m-15 3.75H3m18 0h-1.5M8.25 19.5V21M12 3v1.5m0 15V21m3.75-18v1.5m0 15V21m-9-1.5h10.5a2.25 2.25 0 002.25-2.25V6.75a2.25 2.25 0 00-2.25-2.25H6.75A2.25 2.25 0 004.5 6.75v10.5a2.25 2.25 0 002.25 2.25zm.75-12h9v9h-9v-9z"/></svg>
              {:else if tab.icon === 'shield'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z"/></svg>
              {:else if tab.icon === 'terminal'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M6.75 7.5l3 2.25-3 2.25m4.5 0h3m-9 8.25h13.5A2.25 2.25 0 0021 18V6a2.25 2.25 0 00-2.25-2.25H5.25A2.25 2.25 0 003 6v12a2.25 2.25 0 002.25 2.25z"/></svg>
              {:else if tab.icon === 'info'}
                <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M11.25 11.25l.041-.02a.75.75 0 011.063.852l-.708 2.836a.75.75 0 001.063.853l.041-.021M21 12a9 9 0 11-18 0 9 9 0 0118 0zm-9-3.75h.008v.008H12V8.25z"/></svg>
              {/if}
            </span>
            <span class="rail-label">{tab.label}</span>
          </button>
        </li>
      {/each}
    </ul>
  </nav>

  <!-- Right content panel -->
  <div
    id="settings-panel"
    role="tabpanel"
    class="content-panel"
    aria-label="{TABS.find(t => t.id === activeTab)?.label} settings"
  >
    <div class="panel-scroll">

      <!-- ── General ──────────────────────────────────────────────────────── -->
      {#if activeTab === 'general'}
        <section class="section">
          <h2 class="section-title">General</h2>
          <p class="section-desc">Workspace and display preferences.</p>

          <div class="settings-group">
            <!-- Agent name -->
            <div class="settings-item">
              <div class="item-meta">
                <span class="item-label">Agent name</span>
                <span class="item-hint">Name shown in chat and logs.</span>
              </div>
              <input
                type="text"
                class="field-input"
                bind:value={agentName}
                placeholder="OSA Agent"
                aria-label="Agent name"
                maxlength="64"
              />
            </div>

            <div class="item-divider"></div>

            <!-- Working directory -->
            <div class="settings-item">
              <div class="item-meta">
                <span class="item-label">Working directory</span>
                <span class="item-hint">Default root for file operations.</span>
              </div>
              <div class="dir-row">
                <input
                  type="text"
                  class="field-input dir-input"
                  bind:value={workingDir}
                  placeholder="/Users/you/projects"
                  aria-label="Working directory path"
                  spellcheck={false}
                />
                <button
                  type="button"
                  class="btn-ghost btn-sm"
                  onclick={pickWorkingDir}
                  aria-label="Browse for working directory"
                >
                  <svg width="13" height="13" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 7a2 2 0 012-2h3.586a1 1 0 01.707.293L10.707 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V7z"/></svg>
                  Browse
                </button>
              </div>
            </div>

            <div class="item-divider"></div>

            <!-- Theme -->
            <div class="settings-item">
              <div class="item-meta">
                <span class="item-label">Theme</span>
                <span class="item-hint">Appearance mode.</span>
              </div>
              <select class="field-select" bind:value={theme} aria-label="Theme">
                <option value="dark">Dark</option>
              </select>
            </div>
          </div>

          <div class="save-row">
            <button
              type="button"
              class="btn-primary"
              onclick={saveSettings}
              disabled={saving}
            >
              {#if saving}
                <span class="spinner" aria-hidden="true"></span>
                Saving…
              {:else if saveSuccess}
                <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M5 13l4 4L19 7"/></svg>
                Saved
              {:else}
                Save changes
              {/if}
            </button>
          </div>
        </section>

      <!-- ── Provider ─────────────────────────────────────────────────────── -->
      {:else if activeTab === 'provider'}
        <section class="section">
          <h2 class="section-title">Provider</h2>
          <p class="section-desc">AI provider connection and credentials.</p>

          <!-- Current provider status -->
          <div class="settings-group" style="margin-bottom: 20px;">
            <div class="settings-item">
              <div class="item-meta">
                <span class="item-label">Connected providers</span>
              </div>
              <div class="provider-badges">
                {#each connectedProviders.filter(p => p.connected) as p (p.slug)}
                  <span class="badge badge--active">{p.name}</span>
                {:else}
                  <span class="badge badge--muted">None</span>
                {/each}
              </div>
            </div>
          </div>

          <!-- Provider selector (radio cards) -->
          <div class="field-label-row">
            <span class="field-label-text">Select provider</span>
          </div>
          <div class="provider-grid">
            {#each PROVIDERS as meta (meta.id)}
              {@const isConnected = connectedProviders.some(p => p.slug === meta.id && p.connected)}
              <label
                class="provider-card"
                class:provider-card--selected={selectedProvider === meta.id}
              >
                <input
                  type="radio"
                  name="provider"
                  value={meta.id}
                  bind:group={selectedProvider}
                  class="sr-only"
                  aria-label="Select {meta.name}"
                />
                <div class="pcard-inner">
                  <div class="pcard-top">
                    <span class="pcard-name">{meta.name}</span>
                    {#if isConnected}
                      <span class="pcard-dot pcard-dot--green" aria-label="Connected"></span>
                    {:else}
                      <span class="pcard-dot pcard-dot--gray" aria-label="Not connected"></span>
                    {/if}
                  </div>
                  <span class="pcard-tag">{meta.tagline}</span>
                </div>
              </label>
            {/each}
          </div>

          <!-- API key (only for providers that require it) -->
          {#if PROVIDERS.find(p => p.id === selectedProvider)?.requiresKey}
            <div class="settings-group" style="margin-top: 20px;">
              <div class="settings-item settings-item--col">
                <div class="item-meta">
                  <span class="item-label">API key</span>
                  <span class="item-hint">Stored locally. Never transmitted to third parties.</span>
                </div>
                <div class="sk-input-wrap" style="margin-top: 8px;">
                  <input
                    type={showApiKey ? 'text' : 'password'}
                    class="field-input sk-mono"
                    bind:value={apiKey}
                    placeholder={PROVIDERS.find(p => p.id === selectedProvider)?.keyPlaceholder ?? ''}
                    autocomplete="off"
                    spellcheck={false}
                    aria-label="API key"
                  />
                  <button
                    type="button"
                    class="sk-eye"
                    aria-label={showApiKey ? 'Hide API key' : 'Show API key'}
                    onclick={() => { showApiKey = !showApiKey; }}
                  >
                    {#if showApiKey}
                      <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21"/></svg>
                    {:else}
                      <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/></svg>
                    {/if}
                  </button>
                </div>
              </div>
            </div>
          {/if}

          <!-- Test connection -->
          <div class="save-row" style="margin-top: 20px;">
            <button
              type="button"
              class="btn-ghost"
              onclick={testConnection}
              disabled={testingConnection || !selectedProvider}
            >
              {#if testingConnection}
                <span class="spinner spinner--dark" aria-hidden="true"></span>
                Testing…
              {:else}
                Test connection
              {/if}
            </button>

            {#if connectionStatus === 'ok'}
              <span class="status-pill status-pill--ok">
                <svg width="11" height="11" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M5 13l4 4L19 7"/></svg>
                {connectionMessage}
              </span>
            {:else if connectionStatus === 'error'}
              <span class="status-pill status-pill--error">{connectionMessage}</span>
            {/if}
          </div>
        </section>

      <!-- ── Permissions ───────────────────────────────────────────────────── -->
      {:else if activeTab === 'permissions'}
        <section class="section">
          <h2 class="section-title">Permissions</h2>
          <p class="section-desc">Control what the agent can do without asking.</p>

          <div class="settings-group">
            <!-- YOLO mode -->
            <div class="settings-item">
              <div class="item-meta">
                <span class="item-label">YOLO mode</span>
                <span class="item-hint">Auto-approve all tool calls. No confirmation dialogs.</span>
              </div>
              <button
                type="button"
                role="switch"
                aria-checked={yoloMode}
                aria-label="Toggle YOLO mode"
                class="toggle"
                class:toggle--on={yoloMode}
                onclick={toggleYolo}
              >
                <span class="toggle-knob"></span>
              </button>
            </div>

            <div class="item-divider"></div>

            <!-- Permission tier -->
            <div class="settings-item settings-item--col">
              <div class="item-meta">
                <span class="item-label">Permission tier</span>
                <span class="item-hint">Default scope for new tool approvals.</span>
              </div>
              <div class="tier-group">
                <label class="tier-card" class:tier-card--selected={permTier === 'full'}>
                  <input type="radio" name="perm-tier" value="full" bind:group={permTier} class="sr-only" />
                  <span class="tier-name">Full</span>
                  <span class="tier-desc">All tools enabled</span>
                </label>
                <label class="tier-card" class:tier-card--selected={permTier === 'workspace'}>
                  <input type="radio" name="perm-tier" value="workspace" bind:group={permTier} class="sr-only" />
                  <span class="tier-name">Workspace</span>
                  <span class="tier-desc">Working directory only</span>
                </label>
                <label class="tier-card" class:tier-card--selected={permTier === 'readonly'}>
                  <input type="radio" name="perm-tier" value="readonly" bind:group={permTier} class="sr-only" />
                  <span class="tier-name">Read-only</span>
                  <span class="tier-desc">No write operations</span>
                </label>
              </div>
            </div>
          </div>

          <!-- Always-allowed tools -->
          <div class="field-label-row" style="margin-top: 24px;">
            <span class="field-label-text">Always allowed tools</span>
          </div>
          <div class="always-list">
            {#if alwaysAllowed.length === 0}
              <p class="empty-hint">No tools granted permanent access this session.</p>
            {:else}
              {#each alwaysAllowed as tool (tool)}
                <div class="always-item">
                  <span class="always-tool">{tool}</span>
                  <button
                    type="button"
                    class="btn-remove"
                    aria-label="Remove {tool} from always allowed"
                    onclick={() => removeAlwaysAllowed(tool)}
                  >
                    <svg width="12" height="12" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>
                  </button>
                </div>
              {/each}
            {/if}
          </div>
        </section>

      <!-- ── Advanced ──────────────────────────────────────────────────────── -->
      {:else if activeTab === 'advanced'}
        <section class="section">
          <h2 class="section-title">Advanced</h2>
          <p class="section-desc">Backend connection, logging, and diagnostics.</p>

          <div class="settings-group">
            <!-- Backend URL -->
            <div class="settings-item">
              <div class="item-meta">
                <span class="item-label">Backend URL</span>
                <span class="item-hint">OSA backend address.</span>
              </div>
              <input
                type="url"
                class="field-input"
                bind:value={backendUrl}
                placeholder="http://127.0.0.1:8089"
                spellcheck={false}
                aria-label="Backend URL"
              />
            </div>

            <div class="item-divider"></div>

            <!-- Context window (read-only) -->
            <div class="settings-item">
              <div class="item-meta">
                <span class="item-label">Context window</span>
                <span class="item-hint">Active model's max token limit.</span>
              </div>
              <span class="field-readonly">
                {contextWindow !== null ? contextWindow.toLocaleString() + ' tokens' : '—'}
              </span>
            </div>

            <div class="item-divider"></div>

            <!-- Log level -->
            <div class="settings-item">
              <div class="item-meta">
                <span class="item-label">Log level</span>
                <span class="item-hint">Verbosity for backend logs.</span>
              </div>
              <select class="field-select" bind:value={logLevel} aria-label="Log level">
                <option value="error">Error</option>
                <option value="warn">Warn</option>
                <option value="info">Info</option>
                <option value="debug">Debug</option>
              </select>
            </div>
          </div>

          <!-- Action buttons -->
          <div class="action-row">
            <button
              type="button"
              class="btn-ghost"
              onclick={restartBackend}
              disabled={restartingBackend}
              aria-label="Restart the backend process"
            >
              {#if restartingBackend}
                <span class="spinner spinner--dark" aria-hidden="true"></span>
                Restarting…
              {:else}
                <svg width="13" height="13" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/></svg>
                Restart backend
              {/if}
            </button>

            <button
              type="button"
              class="btn-ghost"
              onclick={runDoctor}
              disabled={runningDoctor}
              aria-label="Run backend health check"
            >
              {#if runningDoctor}
                <span class="spinner spinner--dark" aria-hidden="true"></span>
                Running…
              {:else}
                <svg width="13" height="13" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                Run doctor
              {/if}
            </button>
          </div>

          {#if doctorOutput}
            <div class="doctor-output" role="region" aria-label="Doctor output" aria-live="polite">
              <pre class="doctor-pre">{doctorOutput}</pre>
            </div>
          {/if}
        </section>

      <!-- ── About ─────────────────────────────────────────────────────────── -->
      {:else if activeTab === 'about'}
        <section class="section">
          <h2 class="section-title">About</h2>
          <p class="section-desc">Version information and resources.</p>

          <div class="settings-group">
            <div class="settings-item">
              <span class="item-label">App version</span>
              <span class="field-readonly">v{appVersion}</span>
            </div>

            <div class="item-divider"></div>

            <div class="settings-item">
              <span class="item-label">Backend version</span>
              <span class="field-readonly">
                {#if backendVersion === 'offline'}
                  <span class="status-dot status-dot--error"></span> Offline
                {:else}
                  <span class="status-dot status-dot--ok"></span> v{backendVersion}
                {/if}
              </span>
            </div>

            <div class="item-divider"></div>

            <div class="settings-item">
              <span class="item-label">Agent status</span>
              <span class="field-readonly">
                {#if healthData}
                  {healthData.agents_active} active
                {:else}
                  —
                {/if}
              </span>
            </div>
          </div>

          <div class="link-list">
            <button type="button" class="link-btn" onclick={() => openLink('https://github.com/robertohluna/osa-desktop')}>
              <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M10 20l4-16m4 4l4 4-4 4M6 16l-4-4 4-4"/></svg>
              GitHub
              <svg width="10" height="10" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true" class="ext-icon"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/></svg>
            </button>
            <button type="button" class="link-btn" onclick={() => openLink('https://docs.osa.dev')}>
              <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M12 6.042A8.967 8.967 0 006 3.75c-1.052 0-2.062.18-3 .512v14.25A8.987 8.987 0 016 18c2.305 0 4.408.867 6 2.292m0-14.25a8.966 8.966 0 016-2.292c1.052 0 2.062.18 3 .512v14.25A8.987 8.987 0 0018 18a8.967 8.967 0 00-6 2.292m0-14.25v14.25"/></svg>
              Documentation
              <svg width="10" height="10" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true" class="ext-icon"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/></svg>
            </button>
            <button type="button" class="link-btn" onclick={() => openLink('https://github.com/robertohluna/osa-desktop/issues/new')}>
              <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" d="M12 9v3.75m9-.75a9 9 0 11-18 0 9 9 0 0118 0zm-9 3.75h.008v.008H12v-.008z"/></svg>
              Report an issue
              <svg width="10" height="10" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true" class="ext-icon"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/></svg>
            </button>
          </div>
        </section>
      {/if}

    </div>
  </div>
</div>

<!-- ─────────────────────────────────────────────────────────────────────────── -->
<!-- Styles                                                                      -->
<!-- ─────────────────────────────────────────────────────────────────────────── -->

<style>
  /* ── Root layout ──────────────────────────────────────────────────────────── */

  .settings-root {
    display: flex;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  /* ── Tab rail ─────────────────────────────────────────────────────────────── */

  .tab-rail {
    width: 188px;
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    background: rgba(255, 255, 255, 0.02);
    border-right: 1px solid rgba(255, 255, 255, 0.06);
    padding: 20px 10px;
    overflow-y: auto;
  }

  .rail-header {
    padding: 0 6px 16px;
  }

  .rail-title {
    font-size: 11px;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.3);
    text-transform: uppercase;
    letter-spacing: 0.08em;
  }

  .rail-list {
    list-style: none;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .rail-item {
    display: flex;
    align-items: center;
    gap: 9px;
    width: 100%;
    padding: 8px 10px;
    background: none;
    border: none;
    border-radius: var(--radius-sm);
    color: rgba(255, 255, 255, 0.45);
    font-size: 13px;
    font-weight: 450;
    cursor: pointer;
    transition: background 0.13s ease, color 0.13s ease;
    text-align: left;
  }

  .rail-item:hover {
    background: rgba(255, 255, 255, 0.05);
    color: rgba(255, 255, 255, 0.75);
  }

  .rail-item--active {
    background: rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.92);
    font-weight: 500;
  }

  .rail-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    opacity: 0.85;
  }

  .rail-label {
    flex: 1;
    min-width: 0;
  }

  /* ── Content panel ────────────────────────────────────────────────────────── */

  .content-panel {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  .panel-scroll {
    flex: 1;
    overflow-y: auto;
    padding: 32px 40px 48px;
  }

  /* ── Section ──────────────────────────────────────────────────────────────── */

  .section {
    max-width: 560px;
  }

  .section-title {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.02em;
    margin: 0 0 4px;
  }

  .section-desc {
    font-size: 13px;
    color: var(--text-tertiary);
    margin: 0 0 24px;
  }

  /* ── Settings group (Apple-style inset list) ──────────────────────────────── */

  .settings-group {
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 12px;
    overflow: hidden;
  }

  .settings-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 13px 16px;
    min-height: 52px;
  }

  .settings-item--col {
    flex-direction: column;
    align-items: flex-start;
    gap: 0;
  }

  .item-divider {
    height: 1px;
    background: rgba(255, 255, 255, 0.06);
    margin: 0;
  }

  .item-meta {
    display: flex;
    flex-direction: column;
    gap: 2px;
    flex-shrink: 0;
  }

  .item-label {
    font-size: 14px;
    color: rgba(255, 255, 255, 0.88);
    font-weight: 450;
    white-space: nowrap;
  }

  .item-hint {
    font-size: 11.5px;
    color: var(--text-tertiary);
  }

  /* ── Inputs ───────────────────────────────────────────────────────────────── */

  .field-input {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 8px;
    padding: 7px 12px;
    color: rgba(255, 255, 255, 0.9);
    font-size: 13px;
    outline: none;
    transition: border-color 0.15s ease, background 0.15s ease;
    width: 220px;
    min-width: 0;
  }

  .field-input::placeholder {
    color: rgba(255, 255, 255, 0.2);
  }

  .field-input:focus {
    border-color: rgba(255, 255, 255, 0.22);
    background: rgba(255, 255, 255, 0.07);
  }

  .field-select {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 8px;
    padding: 7px 28px 7px 12px;
    color: rgba(255, 255, 255, 0.9);
    font-size: 13px;
    outline: none;
    cursor: pointer;
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 24 24' fill='none' stroke='%23666' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M6 9l6 6 6-6'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 10px center;
    transition: border-color 0.15s ease;
  }

  .field-select:focus {
    border-color: rgba(255, 255, 255, 0.22);
  }

  .field-readonly {
    font-size: 13px;
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
    display: flex;
    align-items: center;
    gap: 6px;
  }

  /* Working directory row */
  .dir-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .dir-input {
    width: 180px;
  }

  /* sk-style API key input */
  .sk-input-wrap {
    position: relative;
    width: 100%;
  }

  .sk-mono {
    font-family: var(--font-mono);
    font-size: 12px;
    width: 100%;
    padding-right: 40px;
  }

  .sk-eye {
    position: absolute;
    right: 10px;
    top: 50%;
    transform: translateY(-50%);
    background: none;
    border: none;
    color: var(--text-tertiary);
    cursor: pointer;
    padding: 3px;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: color 0.15s ease;
  }

  .sk-eye:hover {
    color: rgba(255, 255, 255, 0.6);
  }

  .sk-eye:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.35);
    border-radius: 4px;
  }

  /* ── Toggle switch ────────────────────────────────────────────────────────── */

  .toggle {
    position: relative;
    width: 44px;
    height: 24px;
    flex-shrink: 0;
    background: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    cursor: pointer;
    transition: background 0.2s ease, border-color 0.2s ease;
    padding: 0;
    outline: none;
  }

  .toggle--on {
    background: rgba(59, 130, 246, 0.55);
    border-color: rgba(59, 130, 246, 0.4);
  }

  .toggle:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.35);
    outline-offset: 2px;
  }

  .toggle-knob {
    position: absolute;
    top: 3px;
    left: 3px;
    width: 16px;
    height: 16px;
    background: rgba(255, 255, 255, 0.85);
    border-radius: var(--radius-full);
    transition: transform 0.2s cubic-bezier(0.4, 0, 0.2, 1), background 0.2s ease;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.35);
  }

  .toggle--on .toggle-knob {
    transform: translateX(20px);
    background: #fff;
  }

  /* ── Provider grid ────────────────────────────────────────────────────────── */

  .provider-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(130px, 1fr));
    gap: 8px;
  }

  .provider-card {
    display: block;
    cursor: pointer;
    border-radius: 10px;
    border: 1px solid rgba(255, 255, 255, 0.07);
    background: rgba(255, 255, 255, 0.03);
    transition: border-color 0.15s ease, background 0.15s ease;
  }

  .provider-card:hover {
    border-color: rgba(255, 255, 255, 0.14);
    background: rgba(255, 255, 255, 0.05);
  }

  .provider-card--selected {
    border-color: rgba(59, 130, 246, 0.45);
    background: rgba(59, 130, 246, 0.08);
  }

  .pcard-inner {
    padding: 12px 14px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .pcard-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
  }

  .pcard-name {
    font-size: 13px;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.88);
  }

  .pcard-tag {
    font-size: 11px;
    color: var(--text-tertiary);
  }

  .pcard-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .pcard-dot--green {
    background: var(--accent-success);
    box-shadow: 0 0 6px rgba(34, 197, 94, 0.5);
  }

  .pcard-dot--gray {
    background: rgba(255, 255, 255, 0.15);
  }

  /* ── Permission tier ──────────────────────────────────────────────────────── */

  .tier-group {
    display: flex;
    gap: 8px;
    margin-top: 10px;
    flex-wrap: wrap;
  }

  .tier-card {
    display: block;
    cursor: pointer;
    border-radius: 9px;
    border: 1px solid rgba(255, 255, 255, 0.07);
    background: rgba(255, 255, 255, 0.03);
    padding: 10px 14px;
    transition: border-color 0.15s ease, background 0.15s ease;
    min-width: 110px;
  }

  .tier-card:hover {
    border-color: rgba(255, 255, 255, 0.13);
    background: rgba(255, 255, 255, 0.05);
  }

  .tier-card--selected {
    border-color: rgba(59, 130, 246, 0.45);
    background: rgba(59, 130, 246, 0.08);
  }

  .tier-name {
    display: block;
    font-size: 13px;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.88);
    margin-bottom: 2px;
  }

  .tier-desc {
    display: block;
    font-size: 11px;
    color: var(--text-tertiary);
  }

  /* ── Always-allowed list ──────────────────────────────────────────────────── */

  .always-list {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .always-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 12px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 8px;
  }

  .always-tool {
    font-size: 12.5px;
    font-family: var(--font-mono);
    color: rgba(255, 255, 255, 0.75);
  }

  .empty-hint {
    font-size: 13px;
    color: var(--text-tertiary);
    padding: 12px 0;
  }

  .btn-remove {
    background: none;
    border: none;
    color: var(--text-tertiary);
    cursor: pointer;
    padding: 3px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 4px;
    transition: color 0.13s ease, background 0.13s ease;
  }

  .btn-remove:hover {
    color: var(--accent-error);
    background: rgba(239, 68, 68, 0.08);
  }

  .btn-remove:focus-visible {
    outline: 2px solid rgba(239, 68, 68, 0.4);
  }

  /* ── Doctor output ────────────────────────────────────────────────────────── */

  .doctor-output {
    margin-top: 16px;
    background: rgba(0, 0, 0, 0.35);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 10px;
    padding: 14px 16px;
  }

  .doctor-pre {
    font-family: var(--font-mono);
    font-size: 12px;
    color: rgba(255, 255, 255, 0.65);
    white-space: pre-wrap;
    word-break: break-all;
    margin: 0;
    line-height: 1.7;
  }

  /* ── About links ──────────────────────────────────────────────────────────── */

  .link-list {
    margin-top: 20px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .link-btn {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 9px 12px;
    background: none;
    border: none;
    color: rgba(255, 255, 255, 0.55);
    font-size: 13px;
    font-weight: 450;
    cursor: pointer;
    border-radius: 8px;
    text-align: left;
    transition: background 0.13s ease, color 0.13s ease;
    width: 100%;
  }

  .link-btn:hover {
    background: rgba(255, 255, 255, 0.04);
    color: rgba(255, 255, 255, 0.85);
  }

  .link-btn:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.3);
    outline-offset: 2px;
  }

  .ext-icon {
    opacity: 0.4;
    margin-left: auto;
  }

  /* ── Badges ───────────────────────────────────────────────────────────────── */

  .provider-badges {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
  }

  .badge {
    display: inline-flex;
    align-items: center;
    padding: 3px 10px;
    border-radius: var(--radius-full);
    font-size: 11.5px;
    font-weight: 500;
  }

  .badge--active {
    background: rgba(34, 197, 94, 0.12);
    border: 1px solid rgba(34, 197, 94, 0.25);
    color: rgba(34, 197, 94, 0.9);
  }

  .badge--muted {
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    color: var(--text-tertiary);
  }

  /* ── Status indicators ────────────────────────────────────────────────────── */

  .status-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .status-dot--ok    { background: var(--accent-success); }
  .status-dot--error { background: var(--accent-error); }

  .status-pill {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 12px;
    padding: 4px 10px;
    border-radius: var(--radius-full);
  }

  .status-pill--ok {
    background: rgba(34, 197, 94, 0.1);
    border: 1px solid rgba(34, 197, 94, 0.2);
    color: rgba(34, 197, 94, 0.9);
  }

  .status-pill--error {
    background: rgba(239, 68, 68, 0.1);
    border: 1px solid rgba(239, 68, 68, 0.2);
    color: rgba(239, 68, 68, 0.9);
  }

  /* ── Buttons ──────────────────────────────────────────────────────────────── */

  .btn-primary {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 8px 18px;
    background: rgba(255, 255, 255, 0.1);
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 8px;
    color: rgba(255, 255, 255, 0.9);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease;
  }

  .btn-primary:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.14);
    border-color: rgba(255, 255, 255, 0.2);
  }

  .btn-primary:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn-primary:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.3);
    outline-offset: 2px;
  }

  .btn-ghost {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 7px 14px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 8px;
    color: rgba(255, 255, 255, 0.6);
    font-size: 13px;
    font-weight: 450;
    cursor: pointer;
    transition: background 0.13s ease, color 0.13s ease, border-color 0.13s ease;
  }

  .btn-ghost:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.07);
    color: rgba(255, 255, 255, 0.85);
    border-color: rgba(255, 255, 255, 0.13);
  }

  .btn-ghost:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }

  .btn-ghost:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.3);
    outline-offset: 2px;
  }

  .btn-sm {
    padding: 6px 10px;
    font-size: 12px;
  }

  /* ── Row helpers ──────────────────────────────────────────────────────────── */

  .save-row {
    margin-top: 20px;
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .action-row {
    margin-top: 20px;
    display: flex;
    align-items: center;
    gap: 10px;
    flex-wrap: wrap;
  }

  .field-label-row {
    margin-bottom: 8px;
  }

  .field-label-text {
    font-size: 12px;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.4);
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }

  /* ── Spinner ──────────────────────────────────────────────────────────────── */

  .spinner {
    display: inline-block;
    width: 13px;
    height: 13px;
    border: 2px solid rgba(255, 255, 255, 0.2);
    border-top-color: rgba(255, 255, 255, 0.8);
    border-radius: var(--radius-full);
    animation: spin 0.6s linear infinite;
    flex-shrink: 0;
  }

  .spinner--dark {
    border-color: rgba(255, 255, 255, 0.12);
    border-top-color: rgba(255, 255, 255, 0.5);
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  @media (prefers-reduced-motion: reduce) {
    .spinner { animation: none; opacity: 0.5; }
    .toggle-knob { transition: none; }
    .toggle { transition: none; }
  }

  /* ── Accessibility utility ────────────────────────────────────────────────── */

  .sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border-width: 0;
  }
</style>
