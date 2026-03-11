<script lang="ts">
  import Chat from '$lib/components/chat/Chat.svelte';
  import { chatStore } from '$lib/stores/chat.svelte';
  import { onMount } from 'svelte';

  // Resolve or generate a persistent session ID for this browser session.
  // In Tauri we could call invoke('get_session_id') from the Rust side for
  // a device-persistent ID; sessionStorage provides tab persistence in the SPA.
  let sessionId = $state('');

  onMount(async () => {
    // Check URL for a specific session ID (e.g. /app?session=abc)
    const urlParams = new URLSearchParams(window.location.search);
    const urlSession = urlParams.get('session');

    if (urlSession) {
      // URL-specified session — load it from backend
      sessionId = urlSession;
      try {
        await chatStore.loadSession(sessionId);
      } catch {
        // Session not found or backend error — start fresh
        chatStore.error = null;
      }
    } else {
      // No session specified — start empty, a session will be created on first message
      sessionId = '';
    }
  });
</script>

<svelte:head>
  <title>Chat — OSA</title>
</svelte:head>

<section class="chat-page" aria-label="Chat">
  <Chat {sessionId} />
</section>

<style>
  .chat-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    padding: 12px;
    box-sizing: border-box;
  }
</style>
