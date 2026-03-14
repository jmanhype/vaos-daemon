# Key UI Components

All components are in `src/lib/components/`. They use Svelte 5 runes syntax (`$props()`, `$state`, `$derived`, `$effect`).

## Chat Interface

### `Chat.svelte` (`src/lib/components/chat/Chat.svelte`)

The primary chat view. Accepts one prop:

```typescript
interface Props {
  sessionId?: string;
}
```

If `sessionId` is passed and differs from `chatStore.currentSession?.id`, the component calls `chatStore.loadSession(sessionId)` via `$effect`.

**Layout structure:**
1. Drop overlay (shown during drag-and-drop file operations)
2. Connection banner (shown when `chatStore.error` is set — "Backend offline" with a Restart button)
3. Message viewport (`role="log"`, `aria-live="polite"`)
4. Scroll-to-bottom FAB (appears when user has scrolled up)
5. Orb dock (small orb between message list and input, shows idle/active video)
6. Attachments bar (chip list of staged files)
7. Input dock (`ChatInput`)

**File attachment:**

`Chat.svelte` handles drag-and-drop (`ondragenter`, `ondragleave`, `ondragover`, `ondrop`). Files are categorized by MIME type and extension:
- Images: read as data URL (base64), shown as thumbnail chips
- Text/code: read as `file.text()`, truncated to 50,000 characters and prepended to the message as a fenced code block
- Other: read as data URL

When the user sends a message with attachments, file context is prepended before the typed text, then `attachedFiles` is cleared.

**Streaming display:**

During streaming:
- If `textBuffer`, `thinkingBuffer`, and `toolCalls` are all empty: shows a typing indicator (three bouncing dots)
- Otherwise: renders a `MessageBubble` with `isStreaming={true}`, passing `streamingToolCalls` (derived from `chatStore.streaming.toolCalls`) and `thinkingText`

**Orb:**

Two looping videos in `static/`:
- `MergedAnimationOS.mp4` — idle state (white background, scaled 2.1x with `mix-blend-mode: multiply` to remove the white)
- `OSLoopingActiveMode.mp4` — active state (black background, `mix-blend-mode: screen` to make black transparent)

The orb appears large (120×120 px) in the empty state and small (36×36 px) in the dock during conversations.

**Orb active condition:** `chatStore.isStreaming || voiceStore.isListening`

### `MessageBubble.svelte` (`src/lib/components/chat/MessageBubble.svelte`)

Renders a single message. Props include `message: Message`, `isStreaming?: boolean`, `streamingToolCalls?`, and `thinkingText?: string`.

User messages are right-aligned; assistant, system, and tool messages are left-aligned (controlled by `.message-row--user` and `.message-row--assistant` classes in `Chat.svelte`).

Contains `ThinkingBlock.svelte` (collapsible reasoning trace), `ToolCall.svelte` (expandable tool call/result), `CodeBlock.svelte` (syntax-highlighted with highlight.js), and `StreamingCursor.svelte` (animated cursor while streaming).

Markdown is rendered via `marked` and sanitized with `DOMPurify`.

### `ChatInput.svelte` (`src/lib/components/chat/ChatInput.svelte`)

Self-contained input component. Props:

```typescript
interface Props {
  disabled?:       boolean;
  onSend:          (text: string) => void;
  placeholder?:    string;
  isListening?:    boolean;  // $bindable
  onFilesAttach?:  (files: FileList | File[]) => void;
}
```

**Auto-resize textarea:** grows up to 200 px, shrinks on clear via `style.height = "auto"` then `scrollHeight`.

**Send conditions:** `!disabled && text.trim().length > 0`. Enter sends, Shift+Enter inserts newline.

**Slash command autocomplete:**

When input starts with `/` and contains no space (and is ≤ 20 chars), a popover menu appears above the input listing commands that match the typed prefix:

```
/help     Show available commands
/clear    Clear chat messages
/model    Switch active model
/new      Start a new session
/agents   List available agents
/settings Open settings
/history  View chat history
/reset    Reset current session
```

Arrow keys navigate the list. Tab or Enter selects. Escape dismisses.

**Voice input:** The toolbar has a mic button (connected to `voiceStore.toggle()`) and a small dropdown chevron for selecting the voice provider (local, Groq Whisper, OpenAI Whisper, Browser Web Speech API). The mic button pulses red (`animation: pulse-opacity`) when `voiceStore.isListening` is true.

**File picker:** A hidden `<input type="file" multiple accept="...">` is triggered by the paperclip toolbar button. Accepted types include images, text, code, JSON, YAML, SQL, and more.

## Terminal (`src/routes/app/terminal/+page.svelte`)

The terminal page integrates xterm.js (`@xterm/xterm` v5.4). Addons loaded:
- `FitAddon` — resizes the terminal to fill the container
- `WebLinksAddon` — makes URLs clickable
- `SearchAddon` — in-buffer search

All three addons are imported dynamically in `onMount` to avoid SSR issues.

**Configuration:**

```typescript
fontFamily: "'SF Mono', 'Fira Code', 'Fira Mono', 'Cascadia Code', ui-monospace, monospace"
fontSize:   13  (adjustable 9–24 via toolbar buttons)
lineHeight: 1.4
cursorBlink: true
cursorStyle: "block"
scrollback:  5000
macOptionIsMeta: true
```

**Readline emulation:**

The `t.onKey()` handler implements full readline-style editing. Supported keys:

| Key | Action |
|---|---|
| Enter | Submit command |
| Backspace | Delete char before cursor |
| Delete | Delete char at cursor |
| Arrow Left/Right | Move cursor |
| Arrow Up/Down | History navigation (100-entry ring) |
| Home/End | Jump to line start/end |
| Ctrl+A/E | Jump to start/end |
| Ctrl+K | Delete to end of line |
| Ctrl+U | Delete to start of line |
| Ctrl+W | Delete word backwards |
| Ctrl+C | Interrupt / clear line |
| Ctrl+L | Clear screen |
| Ctrl+F | Toggle search overlay |
| Tab | Autocomplete slash command |

**Command execution:**

Shell commands (non-`/` prefix) are POSTed to `/api/v1/tools/shell_execute/execute`. The backend returns `{ stdout?, stderr?, exit_code? }`. Stderr is rendered in red (`\x1b[31m`). Non-zero exit codes are shown as `[exit N]` in yellow.

**Slash commands** handled locally (no backend call): `/help`, `/clear`, `/model` (async, queries `/api/v1/models`), `/new`, `/history`, `/restart` (calls `restartBackend()`).

**Slash autocomplete:** Ghost text is rendered in dim color (`\x1b[38;5;240m`) after the cursor, moved back so the cursor stays in position. Tab completes. Works only for commands starting with `/`.

**ResizeObserver:** Debounced at 80 ms, calls `fitAddon.fit()` when the container resizes.

**Search overlay:** Ctrl+F toggles a search bar above the terminal. Uses `searchAddon.findNext()` / `findPrevious()`. Enter goes forward, Shift+Enter goes backwards.

## Onboarding Flow (`src/routes/onboarding/`)

### `+page.svelte` — Step Orchestrator

State machine with steps: `1 | 2 | 3 | "complete"`.

```
Step 1: StepProvider   — select provider (Ollama, LM Studio, Anthropic, OpenAI, etc.)
                         auto-detects local providers via detectLocalProviders()
Step 2: StepApiKey     — API key input (skipped for local providers)
Step 3: StepDirectory  — working directory selection
        "complete"     → StepComplete (auto-redirects after 1800 ms)
```

Navigation: local providers skip step 2 (step 1 → step 3). Escape key goes back. Fly transitions (`svelte/transition`) use `direction * 28` px horizontal offset so forward/backward motion is directional. `prefers-reduced-motion` sets duration to 0.

Progress dots in the footer show step 1–3. Three dots: inactive (6 px circle), active (20 px pill), done (35% opacity).

After step 3, `completeOnboarding({ provider, workingDirectory, apiKey })` is called, which POSTs to the backend and then `StepComplete` auto-redirects to `/`.

### `StepApiKey.svelte`

Renders an API key input with a show/hide toggle. The key is stored in the parent page's `apiKey` state via `bind:apiKey`. Validates that the key is non-empty before enabling the Next button.

### `StepProvider.svelte`

Shows a grid of provider cards. Detected local providers (Ollama, LM Studio) get a "Detected" badge. The selected card gets a highlight. Emits `onSelect(provider)` and `onNext()`.

## Layout Components

### `Sidebar.svelte` (`src/lib/components/layout/Sidebar.svelte`)

Icon sidebar with nav links to all routes. Collapses to icon-only mode (`isCollapsed` prop). Persisted to `localStorage["osa-sidebar-collapsed"]` in the app layout. Receives the `user` prop from `settingsStore`.

Nav entries map to keyboard shortcuts `⌘1`–`⌘0` (registered in the app layout).

## Permission Dialog

### `PermissionOverlay.svelte` (`src/lib/components/permissions/PermissionOverlay.svelte`)

Reads `permissionStore.current` and `permissionStore.hasPending`. Renders a modal dialog when a permission request is in the queue.

Shows: tool name, human-readable description, and relevant file paths. Buttons: **Allow**, **Allow Always**, **Deny**. Each calls the corresponding `permissionStore.allow()`, `permissionStore.allowAlways()`, `permissionStore.deny()` method.

Only one dialog is shown at a time. The queue drains sequentially.

### `PermissionDialog.svelte`

The inner dialog content (used by `PermissionOverlay`). Handles keyboard: Enter confirms the default action (Allow), Escape denies.

## Command Palette (`src/lib/components/palette/CommandPalette.svelte`)

Shown when `paletteStore.isOpen` is true. Registered commands include:
- Navigation to all routes
- New session
- Clear chat
- Toggle YOLO mode
- Restart backend

Triggered by `⌘K`. Commands are registered by the app layout via `paletteStore.registerBuiltins()`.

## Known UX Issues and Limitations

**File attachment backend gap.** The chat frontend prepends file content as plain text in the message string. There is no multipart upload or vision API pass-through to the backend. Image files are noted as `[Attached image: name]` but the actual image data is not sent to the LLM.

**Terminal is not a real PTY.** The terminal emulates readline locally but executes commands by POSTing to the backend's `shell_execute` endpoint. There is no persistent shell session — each command runs in a fresh subprocess. Interactive programs (vim, top, htop) do not work.

**Slash commands in chat are not connected.** `ChatInput.svelte` shows autocomplete for `/help`, `/model`, `/new`, etc., but these are informational UI only. Sending `/clear` does not clear the session; it sends the literal text to the LLM. The intended behavior is to trigger `chatStore.createSession()` and navigate, but this wiring is not implemented.

**Permission POST is best-effort.** The `onDecision` callback in the app layout posts the decision to `/api/v1/sessions/:id/tool_calls/:toolUseId/decision` with `.catch(() => {})`. If the backend does not implement this endpoint, the permission UI shows but the agent does not resume. Whether the backend honors the decision depends on backend version.

**Agent tree hierarchy is inferred.** `agentsStore.agentTree` uses timestamp-based heuristics (2-second batching) because the backend `Agent` type has no `parentId` field. The tree may be incorrect for parallel agents created close together.

**YOLO mode persists only for the session.** `#alwaysAllowed` in `permissionStore` is a non-reactive `Set` that is cleared on page reload. There is no persistence mechanism.
