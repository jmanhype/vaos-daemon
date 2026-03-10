<script lang="ts">
  // /chat — primary chat route linked from the sidebar nav.
  import Chat from '$lib/components/chat/Chat.svelte';
  import { chatStore } from '$lib/stores/chat.svelte';
  import { onMount } from 'svelte';

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

    if (sessionId && chatStore.currentSession?.id !== sessionId) {
      try {
        await chatStore.loadSession(sessionId);
      } catch {
        // First visit — backend has no session yet; chat starts empty.
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
