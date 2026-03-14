<script lang="ts">
  // /app/chat — primary chat route with session list sidebar.
  import { onMount } from 'svelte';
  import { page } from '$app/stores';
  import { goto } from '$app/navigation';
  import { chatStore } from '$lib/stores/chat.svelte';
  import Chat from '$lib/components/chat/Chat.svelte';
  import SessionList from '$lib/components/chat/SessionList.svelte';

  // Resolved session id — set once we confirm the session exists on the backend
  let sessionId = $state('');

  // Session panel collapse state — persisted to localStorage
  let sessionPanelOpen = $state(true);

  function toggleSessionPanel(): void {
    sessionPanelOpen = !sessionPanelOpen;
    localStorage.setItem('osa-session-panel', String(sessionPanelOpen));
  }

  onMount(async () => {
    // Restore session panel state from localStorage
    const panelPref = localStorage.getItem('osa-session-panel');
    if (panelPref !== null) {
      sessionPanelOpen = panelPref !== 'false';
    }

    // Priority 1: URL param (e.g. after creating a new session)
    const urlParam = $page.url.searchParams.get('session');
    if (urlParam) {
      try {
        await chatStore.loadSession(urlParam);
        sessionId = urlParam;
        goto('/app/chat', { replaceState: true });
      } catch {
        sessionId = '';
      }
      return;
    }

    // Priority 2: sessionStorage (persisted across page reloads)
    const stored = sessionStorage.getItem('osa-session-id');
    if (stored && chatStore.currentSession?.id !== stored) {
      try {
        await chatStore.loadSession(stored);
        sessionId = stored;
      } catch {
        sessionStorage.removeItem('osa-session-id');
        sessionId = '';
      }
    } else if (chatStore.currentSession) {
      sessionId = chatStore.currentSession.id;
    }

    // Always ensure the session list is populated for the sidebar
    if (chatStore.sessions.length === 0) {
      chatStore.listSessions();
    }
  });

  // Persist newly created sessions to sessionStorage
  $effect(() => {
    const id = chatStore.currentSession?.id;
    if (id && id !== sessionStorage.getItem('osa-session-id')) {
      sessionStorage.setItem('osa-session-id', id);
      sessionId = id;
    }
  });

  // ── Session list callbacks ────────────────────────────────────────────────────

  async function handleNewSession(): Promise<void> {
    if (chatStore.isStreaming) chatStore.cancelGeneration();
    const session = await chatStore.createSession();
    chatStore.currentSession = session;
    chatStore.messages = [];
    chatStore.pendingUserMessage = null;
    sessionStorage.setItem('osa-session-id', session.id);
    sessionId = session.id;
  }

  async function handleSelectSession(id: string): Promise<void> {
    if (id === sessionId) return;
    try {
      await chatStore.loadSession(id);
      sessionStorage.setItem('osa-session-id', id);
      sessionId = id;
    } catch {
      // Session unavailable — ignore
    }
  }
</script>

<svelte:head>
  <title>Chat — OSA</title>
</svelte:head>

<div class="chat-page" aria-label="Chat">
  <!-- Session sidebar — only rendered when open -->
  {#if sessionPanelOpen}
    <div class="session-sidebar">
      <SessionList
        onNewSession={handleNewSession}
        onSelectSession={handleSelectSession}
      />
    </div>
  {/if}

  <!-- Chat panel: fills remaining space -->
  <div class="chat-panel" class:chat-panel--full={!sessionPanelOpen}>
    <Chat {sessionId} onToggleHistory={toggleSessionPanel} historyOpen={sessionPanelOpen} />
  </div>
</div>

<style>
  .chat-page {
    display: flex;
    height: 100%;
    width: 100%;
    overflow: hidden;
  }

  .session-sidebar {
    flex-shrink: 0;
    height: 100%;
    width: 280px;
    overflow: hidden;
  }

  .chat-panel {
    flex: 1;
    min-width: 0;
    height: 100%;
    padding: 12px 12px 12px 0;
    box-sizing: border-box;
  }

  .chat-panel--full {
    padding-left: 12px;
  }
</style>
