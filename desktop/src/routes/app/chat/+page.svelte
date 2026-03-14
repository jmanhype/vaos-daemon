<script lang="ts">
  // /app/chat — primary chat route linked from the sidebar nav.
  import Chat from '$lib/components/chat/Chat.svelte';
  import { chatStore } from '$lib/stores/chat.svelte';
  import { onMount } from 'svelte';

  // Only set if we confirmed the session exists on the backend.
  let sessionId = $state('');

  onMount(async () => {
    const stored = sessionStorage.getItem('osa-session-id');

    if (stored && chatStore.currentSession?.id !== stored) {
      try {
        await chatStore.loadSession(stored);
        // Session confirmed on backend — safe to pass to Chat.
        sessionId = stored;
      } catch {
        // Session not on backend (first visit or cleared). Remove stale key
        // so we don't keep retrying. chatStore.sendMessage will create a new
        // session on the first message and we'll persist that id below.
        sessionStorage.removeItem('osa-session-id');
        sessionId = '';
      }
    } else if (chatStore.currentSession) {
      // Already loaded (e.g. navigating back within app session).
      sessionId = chatStore.currentSession.id;
    }
  });

  // When chatStore creates a brand-new session (first message), persist it.
  $effect(() => {
    const id = chatStore.currentSession?.id;
    if (id && id !== sessionStorage.getItem('osa-session-id')) {
      sessionStorage.setItem('osa-session-id', id);
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
