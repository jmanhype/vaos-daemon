<script lang="ts">
  interface Props {
    disabled?: boolean;
    onSend: (text: string) => void;
    placeholder?: string;
  }

  let {
    disabled = false,
    onSend,
    placeholder = 'Message OSA… (Enter to send, Shift+Enter for newline)',
  }: Props = $props();

  let text = $state('');
  let textareaEl = $state<HTMLTextAreaElement | null>(null);
  let isFocused = $state(false);

  const canSend = $derived(!disabled && text.trim().length > 0);

  function send() {
    if (!canSend) return;
    const value = text.trim();
    text = '';
    // Reset height after clearing
    if (textareaEl) {
      textareaEl.style.height = 'auto';
    }
    onSend(value);
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      send();
      return;
    }
    // Cmd/Ctrl+K: clear input
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
      e.preventDefault();
      text = '';
      if (textareaEl) textareaEl.style.height = 'auto';
    }
  }

  function resizeTextarea() {
    if (!textareaEl) return;
    textareaEl.style.height = 'auto';
    textareaEl.style.height = `${Math.min(textareaEl.scrollHeight, 200)}px`;
  }

  // Voice input (Web Speech API — available in Tauri webview on macOS/Windows)
  let isListening = $state(false);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let recognition: any = null;

  const hasVoice = $derived(
    typeof window !== 'undefined' &&
      ('SpeechRecognition' in window || 'webkitSpeechRecognition' in window)
  );

  function toggleVoice() {
    if (isListening) {
      recognition?.stop();
      isListening = false;
      return;
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const SR = (window as any).SpeechRecognition ?? (window as any).webkitSpeechRecognition;
    if (!SR) return;

    recognition = new SR();
    recognition.continuous = false;
    recognition.interimResults = true;
    recognition.lang = 'en-US';

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    recognition.onresult = (e: any) => {
      text = Array.from(e.results as ArrayLike<{ 0: { transcript: string } }>)
        .map((r) => r[0].transcript)
        .join('');
      resizeTextarea();
    };

    recognition.onend = () => {
      isListening = false;
    };

    recognition.start();
    isListening = true;
  }
</script>

<div
  class="input-root"
  class:input-root--focused={isFocused}
  class:input-root--disabled={disabled}
>
  <!-- Textarea -->
  <div class="textarea-row">
    <textarea
      bind:this={textareaEl}
      bind:value={text}
      {disabled}
      {placeholder}
      rows={1}
      class="input-textarea"
      oninput={resizeTextarea}
      onkeydown={handleKeydown}
      onfocus={() => {
        isFocused = true;
      }}
      onblur={() => {
        isFocused = false;
      }}
      aria-label="Chat message input"
      aria-multiline="true"
    ></textarea>
  </div>

  <!-- Toolbar -->
  <div class="toolbar">
    <div class="toolbar-left">
      <!-- Voice input -->
      {#if hasVoice}
        <button
          class="toolbar-btn"
          class:toolbar-btn--active={isListening}
          onclick={toggleVoice}
          {disabled}
          aria-label={isListening ? 'Stop voice input' : 'Start voice input'}
          title={isListening ? 'Stop listening' : 'Voice input'}
        >
          <svg
            width="15"
            height="15"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            aria-hidden="true"
          >
            <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z" />
            <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
            <line x1="12" y1="19" x2="12" y2="23" />
            <line x1="8" y1="23" x2="16" y2="23" />
          </svg>
        </button>
      {/if}
    </div>

    <div class="toolbar-right">
      <span class="shortcut-hint" aria-hidden="true">⌘K clear</span>
      <button
        class="send-btn"
        onclick={send}
        disabled={!canSend}
        aria-label="Send message"
        title="Send (Enter)"
      >
        <svg
          width="15"
          height="15"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2.5"
          aria-hidden="true"
        >
          <line x1="22" y1="2" x2="11" y2="13" />
          <polygon points="22 2 15 22 11 13 2 9 22 2" />
        </svg>
      </button>
    </div>
  </div>
</div>

<style>
  .input-root {
    border-radius: 12px;
    border: 1px solid rgba(255, 255, 255, 0.08);
    background: rgba(255, 255, 255, 0.03);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    transition:
      border-color 0.15s,
      box-shadow 0.15s;
    overflow: hidden;
  }

  .input-root--focused {
    border-color: rgba(255, 255, 255, 0.18);
    box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06) inset;
  }

  .input-root--disabled {
    opacity: 0.5;
    pointer-events: none;
  }

  /* Textarea */
  .textarea-row {
    padding: 12px 14px 4px;
  }

  .input-textarea {
    width: 100%;
    min-height: 44px;
    max-height: 200px;
    background: transparent;
    border: none;
    outline: none;
    resize: none;
    color: rgba(255, 255, 255, 0.9);
    font-size: 0.9375rem;
    line-height: 1.6;
    font-family: inherit;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
    display: block;
  }

  .input-textarea::placeholder {
    color: rgba(255, 255, 255, 0.2);
  }

  /* Toolbar */
  .toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 6px 10px 10px;
  }

  .toolbar-left,
  .toolbar-right {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .toolbar-btn {
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: none;
    border: none;
    border-radius: 6px;
    color: rgba(255, 255, 255, 0.35);
    cursor: pointer;
    transition:
      color 0.12s,
      background 0.12s;
  }

  .toolbar-btn:hover {
    color: rgba(255, 255, 255, 0.7);
    background: rgba(255, 255, 255, 0.07);
  }

  .toolbar-btn--active {
    color: #f87171;
    animation: pulse-opacity 1s ease-in-out infinite;
  }

  @keyframes pulse-opacity {
    0%,
    100% {
      opacity: 1;
    }
    50% {
      opacity: 0.5;
    }
  }

  .shortcut-hint {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.15);
    letter-spacing: 0.02em;
    user-select: none;
    padding: 0 4px;
  }

  .send-btn {
    width: 36px;
    height: 36px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 8px;
    border: none;
    background: rgba(255, 255, 255, 0.9);
    color: #000;
    cursor: pointer;
    transition:
      background 0.12s,
      transform 0.1s;
    flex-shrink: 0;
  }

  .send-btn:hover:not(:disabled) {
    background: #fff;
    transform: scale(1.05);
  }

  .send-btn:disabled {
    background: rgba(255, 255, 255, 0.12);
    color: rgba(255, 255, 255, 0.2);
    cursor: not-allowed;
  }
</style>
