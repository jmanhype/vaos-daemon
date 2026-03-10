<script lang="ts">
  import Chat from '$lib/components/chat/Chat.svelte';
  import { chatStore } from '$lib/stores/chat.svelte';
  import { onMount } from 'svelte';

  // Resolve or generate a persistent session ID for this browser session.
  // In Tauri we could call invoke('get_session_id') from the Rust side for
  // a device-persistent ID; sessionStorage provides tab persistence in the SPA.
  let sessionId = $state('');

  onMount(async () => {
    const stored = sessionStorage.getItem('osa-session-id');
    if (stored) {
      sessionId = stored;
    } else {
      const id = crypto.randomUUID();
      sessionStorage.setItem('osa-session-id', id);
      sessionId = id;
    }

    // Load message history if the session already exists on the backend.
    if (sessionId && chatStore.currentSession?.id !== sessionId) {
      try {
        await chatStore.loadSession(sessionId);
      } catch {
        // Session not found — first visit, chat starts empty.
      }
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
