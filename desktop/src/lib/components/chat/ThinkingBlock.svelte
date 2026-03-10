<script lang="ts">
  import { slide } from 'svelte/transition';
  import StreamingCursor from './StreamingCursor.svelte';

  interface Props {
    text: string;
    isExpanded: boolean;
    isStreaming?: boolean;
    onToggle: () => void;
  }

  let { text, isExpanded, isStreaming = false, onToggle }: Props = $props();

  const wordCount = $derived(
    text.trim().length === 0 ? 0 : text.trim().split(/\s+/).length
  );
</script>

<div class="thinking-block">
  <button
    class="thinking-header"
    onclick={onToggle}
    aria-expanded={isExpanded}
    aria-controls="thinking-content"
  >
    <span class="thinking-icon" aria-hidden="true">◎</span>
    <span class="thinking-label">
      {#if isStreaming && text.length === 0}
        <span class="thinking-pulse">Thinking</span><span class="thinking-ellipsis" aria-hidden="true">...</span>
      {:else}
        Extended thinking
      {/if}
    </span>
    {#if !isStreaming || wordCount > 0}
      <span class="thinking-words">{wordCount} words</span>
    {/if}
    <span class="thinking-chevron" class:rotated={isExpanded} aria-hidden="true">›</span>
  </button>

  {#if isExpanded}
    <div
      id="thinking-content"
      class="thinking-body"
      transition:slide={{ duration: 200 }}
    >
      <p class="thinking-text">
        {text}{#if isStreaming}<StreamingCursor />{/if}
      </p>
    </div>
  {/if}
</div>

<style>
  .thinking-block {
    border: 1px solid rgba(139, 92, 246, 0.2);
    border-radius: 8px;
    overflow: hidden;
    background: rgba(139, 92, 246, 0.04);
  }

  .thinking-header {
    width: 100%;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    background: none;
    border: none;
    cursor: pointer;
    text-align: left;
    color: rgba(196, 181, 253, 0.7);
    font-size: 0.8125rem;
    transition: background 0.12s;
  }

  .thinking-header:hover {
    background: rgba(139, 92, 246, 0.07);
  }

  .thinking-icon {
    font-size: 0.875rem;
    color: rgba(167, 139, 250, 0.6);
    flex-shrink: 0;
  }

  .thinking-label {
    font-weight: 500;
    color: rgba(196, 181, 253, 0.8);
    font-size: 0.75rem;
    letter-spacing: 0.02em;
  }

  .thinking-pulse {
    animation: pulse-opacity 1.5s ease-in-out infinite;
  }

  .thinking-ellipsis {
    animation: pulse-opacity 1.5s ease-in-out infinite;
    animation-delay: 0.3s;
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

  .thinking-words {
    font-size: 0.625rem;
    letter-spacing: 0.05em;
    color: rgba(196, 181, 253, 0.3);
    margin-left: auto;
    text-transform: uppercase;
  }

  .thinking-chevron {
    font-size: 1rem;
    color: rgba(196, 181, 253, 0.3);
    transition: transform 0.18s ease;
    display: inline-block;
    flex-shrink: 0;
  }

  .thinking-chevron.rotated {
    transform: rotate(90deg);
  }

  .thinking-body {
    border-top: 1px solid rgba(139, 92, 246, 0.1);
    padding: 12px;
  }

  .thinking-text {
    margin: 0;
    font-size: 0.8125rem;
    line-height: 1.65;
    color: rgba(196, 181, 253, 0.6);
    white-space: pre-wrap;
    font-style: italic;
    word-break: break-word;
  }
</style>
