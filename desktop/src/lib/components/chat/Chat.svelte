<script lang="ts">
  import { onDestroy } from 'svelte';
  import { fly } from 'svelte/transition';
  import { chatStore } from '$lib/stores/chat.svelte';
  import { restartBackend } from '$lib/utils/backend';
  import MessageBubble from './MessageBubble.svelte';
  import ChatInput from './ChatInput.svelte';
  import type { ToolCallRef } from '$lib/api/types';

  interface Props {
    /** Session ID — passed from the route page after it resolves/creates one. */
    sessionId?: string;
  }

  let { sessionId = '' }: Props = $props();

  // ── File attachment state ──────────────────────────────────────────────────
  interface AttachedFile {
    id: string;
    name: string;
    type: string;
    size: number;
    /** base64 data URL for images, raw text for text files */
    content: string;
    /** 'image' | 'text' | 'other' */
    category: 'image' | 'text' | 'other';
  }

  let attachedFiles = $state<AttachedFile[]>([]);
  let isDragOver = $state(false);
  let dragCounter = $state(0);

  const IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/svg+xml'];
  const TEXT_TYPES = ['text/plain', 'text/markdown', 'text/csv', 'text/html', 'text/css', 'text/javascript', 'application/json', 'application/xml'];

  function categorizeFile(type: string, name: string): 'image' | 'text' | 'other' {
    if (IMAGE_TYPES.some(t => type.startsWith(t.split('/')[0]) && type.includes(t.split('/')[1]))) return 'image';
    if (IMAGE_TYPES.includes(type)) return 'image';
    if (TEXT_TYPES.includes(type)) return 'text';
    // Check extension fallback
    const ext = name.split('.').pop()?.toLowerCase() ?? '';
    if (['png','jpg','jpeg','gif','webp','svg'].includes(ext)) return 'image';
    if (['txt','md','csv','html','css','js','ts','json','xml','yaml','yml','toml','py','go','rs','svelte','tsx','jsx','sh','sql','log'].includes(ext)) return 'text';
    return 'other';
  }

  async function processFiles(fileList: FileList | File[]) {
    const files = Array.from(fileList);
    for (const file of files) {
      const category = categorizeFile(file.type, file.name);
      const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

      if (category === 'image') {
        const dataUrl = await readAsDataUrl(file);
        attachedFiles = [...attachedFiles, { id, name: file.name, type: file.type, size: file.size, content: dataUrl, category }];
      } else if (category === 'text') {
        const text = await file.text();
        attachedFiles = [...attachedFiles, { id, name: file.name, type: file.type, size: file.size, content: text, category }];
      } else {
        // For other files, store basic metadata (content will be base64 for potential upload)
        const dataUrl = await readAsDataUrl(file);
        attachedFiles = [...attachedFiles, { id, name: file.name, type: file.type, size: file.size, content: dataUrl, category }];
      }
    }
  }

  function readAsDataUrl(file: File): Promise<string> {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result as string);
      reader.onerror = reject;
      reader.readAsDataURL(file);
    });
  }

  function removeFile(id: string) {
    attachedFiles = attachedFiles.filter(f => f.id !== id);
  }

  function formatFileSize(bytes: number): string {
    if (bytes < 1024) return `${bytes}B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
  }

  function handleDragEnter(e: DragEvent) {
    e.preventDefault();
    dragCounter++;
    isDragOver = true;
  }

  function handleDragLeave(e: DragEvent) {
    e.preventDefault();
    dragCounter--;
    if (dragCounter <= 0) {
      isDragOver = false;
      dragCounter = 0;
    }
  }

  function handleDragOver(e: DragEvent) {
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
  }

  function handleDrop(e: DragEvent) {
    e.preventDefault();
    isDragOver = false;
    dragCounter = 0;
    if (e.dataTransfer?.files && e.dataTransfer.files.length > 0) {
      processFiles(e.dataTransfer.files);
    }
  }

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
    // If files are attached, prepend file context to the message
    if (attachedFiles.length > 0) {
      const fileContext = attachedFiles.map(f => {
        if (f.category === 'text') {
          return `[Attached file: ${f.name} (${formatFileSize(f.size)})]\n\`\`\`\n${f.content.slice(0, 50000)}\n\`\`\``;
        } else if (f.category === 'image') {
          return `[Attached image: ${f.name} (${formatFileSize(f.size)})]`;
        }
        return `[Attached file: ${f.name} (${formatFileSize(f.size)})]`;
      }).join('\n\n');

      text = `${fileContext}\n\n${text}`;
      attachedFiles = [];
    }

    chatStore.sendMessage(text);
    isAtBottom = true;
  }

  // ── Orb state: idle vs active ──────────────────────────────────────────────
  // Active when streaming or voice listening (ChatInput exposes via binding)
  let isVoiceListening = $state(false);
  const orbActive = $derived(chatStore.isStreaming || isVoiceListening);

  onDestroy(() => {
    if (chatStore.isStreaming) {
      chatStore.cancelGeneration();
    }
  });
</script>

<div
  class="chat-root"
  ondragenter={handleDragEnter}
  ondragleave={handleDragLeave}
  ondragover={handleDragOver}
  ondrop={handleDrop}
  role="region"
>
  <!-- Drag overlay -->
  {#if isDragOver}
    <div class="drop-overlay" transition:fly={{ duration: 150, y: 8 }}>
      <div class="drop-inner">
        <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/>
          <polyline points="17 8 12 3 7 8"/>
          <line x1="12" y1="3" x2="12" y2="15"/>
        </svg>
        <span class="drop-text">Drop files here</span>
        <span class="drop-hint">Images, text, code, documents</span>
      </div>
    </div>
  {/if}

  <!-- Connection status banner — subtle, not alarming -->
  {#if chatStore.error}
    <div class="connection-banner" role="status">
      <span class="connection-dot"></span>
      <span class="connection-text">Backend offline</span>
      <span class="connection-hint">Start OSA backend on port 9089</span>
      <button
        class="restart-btn"
        onclick={() => { restartBackend().catch(() => {}); }}
        aria-label="Restart backend"
      >
        Restart
      </button>
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
          <div class="orb-container orb-container--large">
            {#if orbActive}
              <video
                class="orb-active"
                src="/OSLoopingActiveMode.mp4"
                autoplay
                loop
                muted
                playsinline
                aria-hidden="true"
              ></video>
            {:else}
              <video
                class="orb-idle"
                src="/MergedAnimationOS.mp4"
                autoplay
                loop
                muted
                playsinline
                aria-hidden="true"
              ></video>
            {/if}
          </div>
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

  <!-- Orb indicator above input (visible during conversations) -->
  {#if chatStore.messages.length > 0 || chatStore.isStreaming || chatStore.pendingUserMessage}
    <div class="orb-dock">
      <div class="orb-container orb-container--small">
        {#if orbActive}
          <video
            class="orb-active"
            src="/OSLoopingActiveMode.mp4"
            autoplay
            loop
            muted
            playsinline
            aria-hidden="true"
          ></video>
        {:else}
          <img
            src="/OSAIconLogo.png"
            alt=""
            class="orb-idle"
            aria-hidden="true"
          />
        {/if}
      </div>
    </div>
  {/if}

  <!-- Attached files bar -->
  {#if attachedFiles.length > 0}
    <div class="attachments-bar">
      {#each attachedFiles as file (file.id)}
        <div class="attachment-chip" title={file.name}>
          {#if file.category === 'image'}
            <img src={file.content} alt={file.name} class="attachment-thumb" />
          {:else}
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/>
              <polyline points="14 2 14 8 20 8"/>
            </svg>
          {/if}
          <span class="attachment-name">{file.name}</span>
          <span class="attachment-size">{formatFileSize(file.size)}</span>
          <button
            class="attachment-remove"
            onclick={() => removeFile(file.id)}
            aria-label="Remove {file.name}"
          >
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
          </button>
        </div>
      {/each}
    </div>
  {/if}

  <!-- Input dock -->
  <div class="input-dock">
    <ChatInput
      disabled={chatStore.isStreaming}
      onSend={handleSend}
      bind:isListening={isVoiceListening}
      onFilesAttach={processFiles}
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

  /* Connection status banner */
  .connection-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 16px;
    background: rgba(255, 255, 255, 0.03);
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
    font-size: 0.7rem;
    color: var(--text-tertiary);
    flex-shrink: 0;
  }

  .connection-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .connection-text {
    color: var(--text-secondary);
  }

  .connection-hint {
    margin-left: auto;
    color: var(--text-muted);
  }

  .restart-btn {
    padding: 3px 10px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.65rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
    flex-shrink: 0;
  }

  .restart-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.2);
    color: var(--text-primary);
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

  .empty-label {
    font-size: 0.875rem;
    letter-spacing: 0.04em;
    margin: 0;
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

  /* ── Orb system — idle/active crossfade ──────────────────────────── */

  .orb-container {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    border-radius: 50%;
    /* Hard circle clip — ensures video edges are perfectly masked */
    clip-path: circle(50%);
    -webkit-clip-path: circle(50%);
    /* GPU compositing for smooth video playback */
    will-change: clip-path;
    transform: translateZ(0);
  }

  .orb-container--large {
    width: 120px;
    height: 120px;
  }

  .orb-container--small {
    width: 36px;
    height: 36px;
  }

  .orb-idle,
  .orb-active {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    pointer-events: none;
    transition: opacity 0.5s ease;
  }

  /* Idle video has WHITE bg — scale aggressively to push anti-aliased edge outside
     the clip boundary, then multiply blends white away against the dark page bg */
  .orb-idle {
    transform: scale(2.1);
    mix-blend-mode: multiply;
  }

  /* Active video has BLACK bg — same scale so orb fills clip; screen makes black transparent */
  .orb-active {
    transform: scale(2.1);
    mix-blend-mode: screen;
  }

  /* Orb dock — sits between message list and input */
  .orb-dock {
    display: flex;
    justify-content: center;
    padding: 8px 0 4px;
    flex-shrink: 0;
  }

  /* ── Drop overlay ───────────────────────────────────────────── */

  .drop-overlay {
    position: absolute;
    inset: 0;
    z-index: 50;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.7);
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
  }

  .drop-inner {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
    padding: 40px 60px;
    border: 2px dashed rgba(255, 255, 255, 0.25);
    border-radius: 16px;
    color: rgba(255, 255, 255, 0.7);
  }

  .drop-text {
    font-size: 1rem;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.85);
  }

  .drop-hint {
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.35);
  }

  /* ── Attachments bar ───────────────────────────────────────── */

  .attachments-bar {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    padding: 8px 16px;
    border-top: 1px solid rgba(255, 255, 255, 0.06);
    background: rgba(255, 255, 255, 0.02);
    flex-shrink: 0;
  }

  .attachment-chip {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 4px 8px 4px 4px;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 8px;
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.75rem;
    max-width: 200px;
  }

  .attachment-thumb {
    width: 24px;
    height: 24px;
    border-radius: 4px;
    object-fit: cover;
    flex-shrink: 0;
  }

  .attachment-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
    min-width: 0;
  }

  .attachment-size {
    color: rgba(255, 255, 255, 0.3);
    font-size: 0.6875rem;
    flex-shrink: 0;
  }

  .attachment-remove {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    background: none;
    border: none;
    color: rgba(255, 255, 255, 0.35);
    cursor: pointer;
    border-radius: 4px;
    flex-shrink: 0;
    transition: color 0.12s, background 0.12s;
  }

  .attachment-remove:hover {
    color: rgba(255, 255, 255, 0.8);
    background: rgba(255, 255, 255, 0.1);
  }

  /* Input dock */
  .input-dock {
    border-top: 1px solid rgba(255, 255, 255, 0.06);
    padding: 12px 16px 16px;
    flex-shrink: 0;
  }
</style>
