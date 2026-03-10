<script lang="ts">
  import { marked } from 'marked';
  import DOMPurify from 'dompurify';
  import ToolCall from './ToolCall.svelte';
  import ThinkingBlock from './ThinkingBlock.svelte';
  import StreamingCursor from './StreamingCursor.svelte';
  import type { Message, ToolCallRef } from '$lib/api/types';

  interface ToolCallState {
    tool: ToolCallRef;
    result?: string;
    isError?: boolean;
    isRunning?: boolean;
    isExpanded: boolean;
  }

  interface Props {
    message: Message;
    isStreaming?: boolean;
    /** Live tool call state during streaming (augments message.tool_calls) */
    streamingToolCalls?: ToolCallState[];
    /** Thinking text — may differ from message.thinking during streaming */
    thinkingText?: string;
    thinkingStreaming?: boolean;
  }

  let {
    message,
    isStreaming = false,
    streamingToolCalls = [],
    thinkingText,
    thinkingStreaming = false,
  }: Props = $props();

  const isUser = $derived(message.role === 'user');

  // Expand/collapse state for thinking block — local to this bubble
  let thinkingExpanded = $state(false);

  // Per-tool expansion state keyed by tool ID
  let toolExpansions = $state<Record<string, boolean>>({});

  function toggleTool(toolId: string) {
    toolExpansions = {
      ...toolExpansions,
      [toolId]: !toolExpansions[toolId],
    };
  }

  function toggleThinking() {
    thinkingExpanded = !thinkingExpanded;
  }

  // Determine active thinking content
  const activeThinking = $derived(
    thinkingText ?? message.thinking?.thinking ?? ''
  );
  const hasThinking = $derived(activeThinking.length > 0 || thinkingStreaming);

  // Determine active tool calls to display
  const activeCalls = $derived((): ToolCallState[] => {
    if (streamingToolCalls.length > 0) return streamingToolCalls;
    if (!message.tool_calls) return [];
    return message.tool_calls.map((tc) => ({
      tool: tc,
      isExpanded: toolExpansions[tc.id] ?? false,
    }));
  });

  // Parse markdown — memoized on content change
  const renderedContent = $derived(() => {
    if (!message.content) return '';
    // Extract fenced code blocks before passing to marked so CodeBlock renders them
    // Here we use marked directly; code blocks inside will be rendered as <pre><code>
    // The {@html} directive outputs the parsed HTML from marked
    try {
      const raw = marked.parse(message.content, { async: false }) as string;
      return DOMPurify.sanitize(raw);
    } catch {
      return DOMPurify.sanitize(message.content);
    }
  });

  function formatTimestamp(ts: string): string {
    try {
      return new Date(ts).toLocaleTimeString([], {
        hour: '2-digit',
        minute: '2-digit',
      });
    } catch {
      return '';
    }
  }
</script>

<article
  class="bubble bubble--{message.role}"
  class:bubble--streaming={isStreaming}
  aria-label={message.role === 'user' ? 'Your message' : 'Agent message'}
>
  {#if !isUser}
    <header class="bubble-header">
      <span class="bubble-author">OSA</span>
      {#if isStreaming}
        <span class="streaming-badge" aria-live="polite" aria-atomic="true">generating</span>
      {/if}
    </header>
  {/if}

  <!-- Thinking block (above text content) -->
  {#if hasThinking}
    <div class="bubble-section">
      <ThinkingBlock
        text={activeThinking}
        isExpanded={thinkingExpanded}
        isStreaming={thinkingStreaming}
        onToggle={toggleThinking}
      />
    </div>
  {/if}

  <!-- Tool calls -->
  {#if activeCalls().length > 0}
    <div class="bubble-section bubble-section--tools">
      {#each activeCalls() as tc (tc.tool.id)}
        <ToolCall
          tool={tc.tool}
          result={tc.result}
          isError={tc.isError}
          isRunning={tc.isRunning}
          isExpanded={tc.isExpanded ?? (toolExpansions[tc.tool.id] ?? false)}
          onToggle={() => toggleTool(tc.tool.id)}
        />
      {/each}
    </div>
  {/if}

  <!-- Message content -->
  {#if message.content}
    <div class="bubble-content">
      {@html renderedContent()}
      {#if isStreaming}
        <StreamingCursor />
      {/if}
    </div>
  {:else if isStreaming}
    <!-- Empty streaming — show standalone cursor -->
    <div class="bubble-content bubble-content--empty">
      <StreamingCursor standalone />
    </div>
  {/if}

  <time class="bubble-time" datetime={message.timestamp}>
    {formatTimestamp(message.timestamp)}
  </time>
</article>

<style>
  .bubble {
    position: relative;
    max-width: min(80%, 680px);
    border-radius: 14px;
    padding: 12px 16px;
    border: 1px solid transparent;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  /* User bubble: right-aligned, white glass */
  .bubble--user {
    background: rgba(255, 255, 255, 0.07);
    border-color: rgba(255, 255, 255, 0.12);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    color: rgba(255, 255, 255, 0.92);
  }

  /* Assistant bubble: left-aligned, darker glass */
  .bubble--assistant {
    background: rgba(255, 255, 255, 0.04);
    border-color: rgba(255, 255, 255, 0.07);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    color: rgba(255, 255, 255, 0.85);
  }

  /* System bubble: subtle warning tint */
  .bubble--system {
    background: rgba(234, 179, 8, 0.07);
    border-color: rgba(234, 179, 8, 0.15);
    color: rgba(253, 224, 71, 0.85);
    font-size: 0.8125rem;
    font-style: italic;
  }

  .bubble--streaming {
    border-color: rgba(255, 255, 255, 0.1);
  }

  .bubble-header {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 2px;
  }

  .bubble-author {
    font-size: 0.6875rem;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.35);
  }

  .streaming-badge {
    font-size: 0.625rem;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.25);
    animation: pulse-opacity 1.5s ease-in-out infinite;
  }

  @keyframes pulse-opacity {
    0%,
    100% {
      opacity: 0.4;
    }
    50% {
      opacity: 1;
    }
  }

  .bubble-section {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .bubble-section--tools {
    gap: 6px;
  }

  .bubble-content {
    font-size: 0.9375rem;
    line-height: 1.65;
    word-break: break-word;
  }

  .bubble-content--empty {
    min-height: 1.4em;
  }

  /* Markdown-rendered content resets */
  .bubble-content :global(p) {
    margin: 0 0 0.6em;
  }

  .bubble-content :global(p:last-child) {
    margin-bottom: 0;
  }

  .bubble-content :global(ul),
  .bubble-content :global(ol) {
    margin: 0.4em 0 0.6em;
    padding-left: 1.4em;
  }

  .bubble-content :global(li) {
    margin-bottom: 0.25em;
  }

  .bubble-content :global(h1),
  .bubble-content :global(h2),
  .bubble-content :global(h3),
  .bubble-content :global(h4) {
    margin: 0.8em 0 0.4em;
    font-weight: 600;
    line-height: 1.3;
  }

  .bubble-content :global(h1) { font-size: 1.15em; }
  .bubble-content :global(h2) { font-size: 1.05em; }
  .bubble-content :global(h3) { font-size: 0.975em; }

  .bubble-content :global(code) {
    font-family: 'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace;
    font-size: 0.85em;
    background: rgba(255, 255, 255, 0.08);
    padding: 1px 5px;
    border-radius: 4px;
    border: 1px solid rgba(255, 255, 255, 0.08);
  }

  .bubble-content :global(pre) {
    margin: 0.5em 0;
    padding: 12px 14px;
    background: rgba(0, 0, 0, 0.45);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 8px;
    overflow-x: auto;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .bubble-content :global(pre code) {
    background: transparent;
    border: none;
    padding: 0;
    font-size: 0.8125rem;
    line-height: 1.6;
    white-space: pre;
  }

  .bubble-content :global(blockquote) {
    margin: 0.5em 0;
    padding: 6px 12px;
    border-left: 3px solid rgba(255, 255, 255, 0.15);
    color: rgba(255, 255, 255, 0.55);
    font-style: italic;
  }

  .bubble-content :global(a) {
    color: rgba(147, 197, 253, 0.9);
    text-decoration: underline;
    text-underline-offset: 2px;
  }

  .bubble-content :global(a:hover) {
    color: #93c5fd;
  }

  .bubble-content :global(hr) {
    border: none;
    border-top: 1px solid rgba(255, 255, 255, 0.1);
    margin: 0.8em 0;
  }

  .bubble-content :global(table) {
    border-collapse: collapse;
    width: 100%;
    font-size: 0.875em;
    margin: 0.5em 0;
  }

  .bubble-content :global(th),
  .bubble-content :global(td) {
    border: 1px solid rgba(255, 255, 255, 0.1);
    padding: 4px 10px;
    text-align: left;
  }

  .bubble-content :global(th) {
    background: rgba(255, 255, 255, 0.05);
    font-weight: 600;
  }

  .bubble-time {
    display: block;
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.2);
    text-align: right;
    margin-top: 4px;
  }
</style>
