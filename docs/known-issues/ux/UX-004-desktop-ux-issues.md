# UX-004: General Desktop UX Issues

> **Severity:** UX
> **Status:** Open
> **Component:** `desktop/src/lib/components/chat/`, `desktop/src/routes/app/`
> **Reported:** 2026-03-14

---

## Summary

Several desktop UI polish issues degrade the experience for first-time and daily
users. These are grouped here as they share no single root cause but are all
visible in production.

## Issues

### 1. No loading state when fetching sessions on startup

`SessionPanel.svelte` renders the session list immediately on mount. If
`sessions.list()` is slow (backend starting up), the panel displays an empty
list with no spinner or skeleton. Users assume they have no sessions and may
start a new one unnecessarily.

**Location:** `desktop/src/lib/components/sessions/SessionPanel.svelte`
**Fix:** Add `let loading = $state(true)` and show a skeleton list while the
promise resolves.

### 2. Error state not shown when backend is unreachable

The connection store (`connection.svelte.ts`) tracks `isConnected`, but the
chat page (`routes/chat/+page.svelte`) does not render an error banner when
`isConnected` is `false`. The input box is still enabled, allowing users to
type and send messages that silently fail.

**Fix:** Disable the `ChatInput` and show a reconnecting banner when
`connection.isConnected === false`.

### 3. Inconsistent glass styling between routes

The Models page (`/app/models/+page.svelte`) uses hardcoded `rgba()` values for
glass backgrounds (e.g. `background: rgba(255,255,255,0.04)`), while the Chat
page uses CSS custom properties (`--glass-bg`). This causes visual inconsistency
when the theme changes (dark/light toggle defined in `theme.svelte.ts`).

**Fix:** Audit all `rgba()` hardcodes in `+page.svelte` files under
`/desktop/src/routes/app/` and replace with `var(--glass-bg)`,
`var(--glass-border)` etc. from the theme token set.

### 4. No confirmation dialog before deleting a session

`SessionPanel.svelte` calls `sessions.delete(id)` directly on click. There is
no confirmation step. A mis-click permanently deletes conversation history.

**Fix:** Show a `<dialog>` confirmation before executing the delete, or add
an undo mechanism (soft-delete with 5-second window).

### 5. Streaming cursor visible after generation ends

`StreamingCursor.svelte` is conditionally rendered via `{#if isStreaming}` in
`MessageBubble.svelte` line 142. If the SSE `done` event is delayed or lost,
`isStreaming` remains `true` indefinitely and the blinking cursor persists.

**Fix:** Add a 30-second timeout in the chat store that sets `isStreaming =
false` if no SSE event is received.

## Impact

- New users are confused by empty session list and disabled-looking UI.
- Mid-conversation backend restarts leave users with a broken chat that shows
  no error.
- Session deletion accidents result in unrecoverable history loss.
