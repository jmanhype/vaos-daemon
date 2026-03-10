<script lang="ts">
  import { onDestroy } from 'svelte';
  import { fly } from 'svelte/transition';
  import { chatStore } from '$lib/stores/chat.svelte';
  import MessageBubble from './MessageBubble.svelte';
  import ChatInput from './ChatInput.svelte';
  import type { ToolCallRef } from '$lib/api/types';

  interface Props {
    /** Session ID — passed from the route page after it resolves/creates one. */
    sessionId?: string;
  }

  let { sessionId = '' }: Props = $props();

  // If the route passes a sessionId and the store isn't already on that session,
  // load it. The route page also does this but Chat guards here for robustness.
  $effect(() => {
    if (sessionId && chatStore.currentSession?.id !== sessionId) {
      chatStore.loadSession(sessionId).catch(() => {
        // Session not on backend yet — fine, first message will create it.
      });
    }
  });

  // Viewport element for scroll management
  let viewportEl = $state<HTMLDivElement | null>(null);
  let isAtBottom = $state(true);

  // Whether the streaming assistant bubble should show the typing indicator
  // (streaming active AND no content yet)
  const showTypingDots = $derived(
    chatStore.isStreaming &&
    chatStore.streaming.textBuffer.length === 0 &&
    chatStore.streaming.toolCalls.length === 0 &&
    chatStore.streaming.thinkingBuffer.length === 0
  );

  // Build the live streaming tool call states for display
  const streamingToolStates = $derived(
    chatStore.streaming.toolCalls.map((tc) => ({
      tool: tc as unknown as ToolCallRef,
      result: (tc as { result?: string }).result,
      isError: false,
      isRunning: !('result' in tc && tc.result !== undefined),
      isExpanded: false,
    }))
  );

  // Auto-scroll effect — fires whenever messages or streaming buffer change
  $effect(() => {
    // Track reactive dependencies
    const _msgs = chatStore.messages;
    const _buf = chatStore.streaming.textBuffer;
    const _thinking = chatStore.streaming.thinkingBuffer;
    void _msgs, _buf, _thinking;

    if (isAtBottom && viewportEl) {
      requestAnimationFrame(() => {
        if (viewportEl) {
          viewportEl.scrollTop = viewportEl.scrollHeight;
        }
      });
    }
  });

  function handleScroll() {
    if (!viewportEl) return;
    const { scrollTop, scrollHeight, clientHeight } = viewportEl;
    isAtBottom = scrollHeight - scrollTop - clientHeight < 40;
  }

  function scrollToBottom() {
    isAtBottom = true;
    viewportEl?.scrollTo({ top: viewportEl.scrollHeight, behavior: 'smooth' });
  }

  function handleSend(text: string) {
    chatStore.sendMessage(text);
    isAtBottom = true;
  }

  onDestroy(() => {
    if (chatStore.isStreaming) {
      chatStore.cancelGeneration();
    }
  });
</script>

<div class="chat-root">
  <!-- Error banner -->
  {#if chatStore.error}
    <div class="connection-error" role="alert">
      <span>{chatStore.error}</span>
      <span class="error-hint">Check connection to backend</span>
    </div>
  {/if}

  <!-- Message list viewport -->
  <div
    class="message-viewport"
    bind:this={viewportEl}
    onscroll={handleScroll}
    aria-label="Chat messages"
    aria-live="polite"
    aria-relevant="additions"
    role="log"
  >
    <div class="message-list">
      <!-- Empty state -->
      {#if chatStore.messages.length === 0 && !chatStore.isStreaming && !chatStore.pendingUserMessage}
        <div class="empty-state" transition:fly={{ y: 16, duration: 300 }}>
          <div class="empty-orb" aria-hidden="true"></div>
          <p class="empty-label">Start a conversation</p>
        </div>
      {/if}

      <!-- Persisted messages -->
      {#each chatStore.messages as message (message.id)}
        <div
          class="message-row message-row--{message.role}"
          transition:fly={{ y: 12, duration: 220 }}
        >
          <MessageBubble {message} />
        </div>
      {/each}

      <!-- Optimistic pending user message -->
      {#if chatStore.pendingUserMessage}
        {@const pending = chatStore.pendingUserMessage}
        <div
          class="message-row message-row--user"
          transition:fly={{ y: 12, duration: 220 }}
        >
          <MessageBubble message={pending} />
        </div>
      {/if}

      <!-- Live assistant streaming bubble -->
      {#if chatStore.isStreaming}
        <div
          class="message-row message-row--assistant"
          transition:fly={{ y: 12, duration: 220 }}
        >
          {#if showTypingDots}
            <!-- No content yet — show typing indicator -->
            <div class="typing-indicator" aria-label="Agent is typing">
              <span class="dot"></span>
              <span class="dot"></span>
              <span class="dot"></span>
            </div>
          {:else}
            <!-- Live streaming bubble — synthesise a Message-shaped object -->
            <MessageBubble
              message={{
                id: 'streaming',
                role: 'assistant',
                content: chatStore.streaming.textBuffer,
                timestamp: new Date().toISOString(),
              }}
              isStreaming={true}
              streamingToolCalls={streamingToolStates}
              thinkingText={chatStore.streaming.thinkingBuffer}
              thinkingStreaming={chatStore.streaming.thinkingBuffer.length > 0 &&
                chatStore.isStreaming}
            />
          {/if}
        </div>
      {/if}
    </div>
  </div>

  <!-- Scroll-to-bottom FAB -->
  {#if !isAtBottom}
    <button
      class="scroll-btn"
      aria-label="Scroll to latest message"
      onclick={scrollToBottom}
      transition:fly={{ y: 8, duration: 150 }}
    >
      <svg
        width="16"
        height="16"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2.5"
        aria-hidden="true"
      >
        <polyline points="6 9 12 15 18 9"></polyline>
      </svg>
    </button>
  {/if}

  <!-- Input dock -->
  <div class="input-dock">
    <ChatInput
      disabled={chatStore.isStreaming}
      onSend={handleSend}
    />
  </div>
</div>

<style>
  .chat-root {
    position: relative;
    display: flex;
    flex-direction: column;
    height: 100%;
    background: rgba(0, 0, 0, 0.6);
    backdrop-filter: blur(24px) saturate(180%);
    -webkit-backdrop-filter: blur(24px) saturate(180%);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 16px;
    overflow: hidden;
  }

  /* Error banner */
  .connection-error {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 16px;
    background: rgba(239, 68, 68, 0.15);
    border-bottom: 1px solid rgba(239, 68, 68, 0.25);
    font-size: 0.75rem;
    color: #fca5a5;
    flex-shrink: 0;
  }

  .error-hint {
    color: rgba(252, 165, 165, 0.6);
  }

  /* Scrollable message area */
  .message-viewport {
    flex: 1;
    overflow-y: auto;
    overflow-x: hidden;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.1) transparent;
  }

  .message-viewport::-webkit-scrollbar {
    width: 4px;
  }

  .message-viewport::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 2px;
  }

  .message-list {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 20px 16px;
    min-height: 100%;
    justify-content: flex-end;
  }

  .message-row {
    display: flex;
  }

  .message-row--user {
    justify-content: flex-end;
  }

  .message-row--assistant,
  .message-row--system,
  .message-row--tool {
    justify-content: flex-start;
  }

  /* Empty state */
  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 16px;
    padding: 60px 0;
    color: rgba(255, 255, 255, 0.3);
    flex: 1;
  }

  .empty-orb {
    width: 48px;
    height: 48px;
    border-radius: 50%;
    background: radial-gradient(circle at 35% 35%, #ffffff22, #00000000);
    border: 1px solid rgba(255, 255, 255, 0.12);
    animation: breathe 3s ease-in-out infinite;
  }

  .empty-label {
    font-size: 0.875rem;
    letter-spacing: 0.04em;
    margin: 0;
  }

  @keyframes breathe {
    0%,
    100% {
      transform: scale(1);
      opacity: 0.5;
    }
    50% {
      transform: scale(1.08);
      opacity: 0.9;
    }
  }

  /* Typing indicator dots */
  .typing-indicator {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 14px 16px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 14px;
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
  }

  .dot {
    display: inline-block;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.4);
    animation: bounce 1.2s ease-in-out infinite;
  }

  .dot:nth-child(2) {
    animation-delay: 0.2s;
  }
  .dot:nth-child(3) {
    animation-delay: 0.4s;
  }

  @keyframes bounce {
    0%,
    80%,
    100% {
      transform: translateY(0);
    }
    40% {
      transform: translateY(-6px);
    }
  }

  /* Scroll-to-bottom FAB */
  .scroll-btn {
    position: absolute;
    bottom: 80px;
    right: 16px;
    width: 32px;
    height: 32px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.1);
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    border: 1px solid rgba(255, 255, 255, 0.15);
    color: rgba(255, 255, 255, 0.7);
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition:
      background 0.15s,
      transform 0.15s;
    z-index: 10;
  }

  .scroll-btn:hover {
    background: rgba(255, 255, 255, 0.18);
    transform: translateY(-1px);
  }

  /* Input dock */
  .input-dock {
    border-top: 1px solid rgba(255, 255, 255, 0.06);
    padding: 12px 16px 16px;
    flex-shrink: 0;
  }
</style>
