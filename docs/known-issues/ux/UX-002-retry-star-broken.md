# UX-002: Retry and Star Buttons Don't Work in Desktop App

> **Severity:** UX
> **Status:** Open
> **Component:** `desktop/src/lib/components/chat/MessageBubble.svelte`, `desktop/src/lib/stores/chat.svelte.ts`
> **Reported:** 2026-03-14

---

## Summary

The message bubble component (`MessageBubble.svelte`) does not render retry or
star/bookmark action buttons. The `Message` type in `types.ts` does not define
these actions, and there is no `onRetry` or `onStar` callback prop. Any UI that
attempts to trigger a retry re-send must duplicate the message send logic
directly, which has not been implemented.

## Symptom

- No retry button appears on assistant messages that error.
- No bookmark/star button appears on any message.
- Users who want to re-run a failed request must retype the message manually.

## Root Cause

`MessageBubble.svelte` (line 17–33) defines props:

```typescript
interface Props {
  message: Message;
  isStreaming?: boolean;
  streamingToolCalls?: ToolCallState[];
  thinkingText?: string;
  thinkingStreaming?: boolean;
}
```

There is no `onRetry`, `onStar`, or `onCopy` callback. The template renders
thinking blocks, tool calls, and message content, but has no action row section.
The `Message` type in `desktop/src/lib/api/types.ts` similarly lacks a
`starred` or `bookmarked` boolean field.

The `chat.svelte.ts` store manages the message list but has no `retryMessage(id)`
or `starMessage(id)` functions. Retry would require:
1. Finding the most recent user message before the failed assistant message.
2. Re-sending it via the SSE send path.
3. Replacing the failed assistant message in the store.

None of this plumbing exists.

## Impact

- Failed generations require the user to retype their full prompt.
- There is no way to bookmark notable responses for later reference.
- Copy-to-clipboard is also absent from the bubble template, though browser
  selection still works.

## Suggested Fix

Add an action row to `MessageBubble.svelte` for assistant messages:

```svelte
{#if !isUser && !isStreaming}
  <div class="bubble-actions" role="toolbar" aria-label="Message actions">
    <button class="action-btn" onclick={onCopy} aria-label="Copy message">
      <!-- clipboard icon -->
    </button>
    <button class="action-btn" onclick={onRetry} aria-label="Retry">
      <!-- retry icon -->
    </button>
    <button class="action-btn" class:starred={message.starred}
            onclick={onStar} aria-label="Star message">
      <!-- star icon -->
    </button>
  </div>
{/if}
```

Add corresponding `onRetry`, `onStar`, `onCopy` props and implement the store
actions in `chat.svelte.ts`.

## Workaround

Retype the prompt manually. Use browser text selection to copy message content.
