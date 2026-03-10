// src/lib/stores/chat.svelte.ts
// Chat store — Svelte 5 class with $state fields.
// Manages sessions, messages, and the active SSE stream lifecycle.

import type { Message, Session, StreamEvent, ToolCallRef } from "$api/types";
import { messages as messagesApi, sessions as sessionsApi } from "$api/client";
import { streamMessage, type StreamController } from "$api/sse";

// ── Types ──────────────────────────────────────────────────────────────────────

export interface StreamingMessage {
  /** Incremental text buffer during streaming */
  textBuffer: string;
  /** Incremental thinking buffer during streaming */
  thinkingBuffer: string;
  /** Tool calls accumulated during this stream */
  toolCalls: ToolCallRef[];
}

// ── Chat Store Class ──────────────────────────────────────────────────────────

class ChatStore {
  // Session list — all sessions visible in the sidebar
  sessions = $state<Session[]>([]);

  // Currently active session
  currentSession = $state<Session | null>(null);

  // Messages for the active session
  messages = $state<Message[]>([]);

  // Optimistic user message (shown immediately before the server echo)
  pendingUserMessage = $state<Message | null>(null);

  // Live state during an active stream
  streaming = $state<StreamingMessage>({
    textBuffer: "",
    thinkingBuffer: "",
    toolCalls: [],
  });

  isStreaming = $state(false);
  isLoadingSessions = $state(false);
  isLoadingMessages = $state(false);
  error = $state<string | null>(null);

  // Private — not reactive, no need to expose
  #streamController: StreamController | null = null;

  /**
   * Raw event listeners — called for every SSE event before the store
   * processes it. Use this to forward events to other stores (tasks, survey,
   * permissions) without coupling the chat store to them directly.
   *
   * Register with `chatStore.addStreamListener(fn)` and clean up with
   * `chatStore.removeStreamListener(fn)`.
   */
  #streamListeners: Array<(event: StreamEvent) => void> = [];

  addStreamListener(fn: (event: StreamEvent) => void): void {
    this.#streamListeners = [...this.#streamListeners, fn];
  }

  removeStreamListener(fn: (event: StreamEvent) => void): void {
    this.#streamListeners = this.#streamListeners.filter((l) => l !== fn);
  }

  // ── Session Operations ──────────────────────────────────────────────────────

  async listSessions(): Promise<void> {
    this.isLoadingSessions = true;
    this.error = null;
    try {
      const data = await sessionsApi.list();
      this.sessions = data;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.isLoadingSessions = false;
    }
  }

  async createSession(title?: string, model?: string): Promise<Session> {
    const { session } = await sessionsApi.create({ title, model });
    this.sessions = [session, ...this.sessions];
    return session;
  }

  async loadSession(sessionId: string): Promise<void> {
    this.isLoadingMessages = true;
    this.error = null;

    // Cancel any active stream before switching sessions
    this.cancelGeneration();

    try {
      const [session, msgs] = await Promise.all([
        sessionsApi.get(sessionId),
        messagesApi.list(sessionId),
      ]);
      this.currentSession = session;
      this.messages = msgs;
      this.pendingUserMessage = null;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.isLoadingMessages = false;
    }
  }

  async deleteSession(sessionId: string): Promise<void> {
    await sessionsApi.delete(sessionId);
    this.sessions = this.sessions.filter((s) => s.id !== sessionId);
    if (this.currentSession?.id === sessionId) {
      this.currentSession = null;
      this.messages = [];
    }
  }

  // ── Message Operations ──────────────────────────────────────────────────────

  async sendMessage(content: string, model?: string): Promise<void> {
    if (this.isStreaming) return;
    if (!content.trim()) return;

    this.error = null;

    // Ensure we have an active session
    let sessionId = this.currentSession?.id;
    if (!sessionId) {
      const session = await this.createSession(undefined, model);
      this.currentSession = session;
      sessionId = session.id;
    }

    // Optimistic user message — displayed immediately
    const optimisticId = `optimistic-${Date.now()}`;
    this.pendingUserMessage = {
      id: optimisticId,
      role: "user",
      content,
      timestamp: new Date().toISOString(),
    };

    // Reset streaming state
    this.streaming = { textBuffer: "", thinkingBuffer: "", toolCalls: [] };
    this.isStreaming = true;

    try {
      // POST the message — backend returns a stream_id
      await messagesApi.send({ session_id: sessionId, content, model });

      // Open the SSE stream
      this.#streamController = streamMessage({
        sessionId,
        content,
        model,
        onEvent: (event: StreamEvent) => this.#handleStreamEvent(event),
        onConnect: () => {
          this.error = null;
        },
        onDisconnect: () => {
          // Stream closed; isStreaming is set to false in onDone / onError
        },
        onError: (err: Error) => {
          this.error = err.message;
          this.isStreaming = false;
          this.#streamController = null;
        },
        onDone: () => {
          this.#finalizeStream();
        },
      });
    } catch (e) {
      this.error = (e as Error).message;
      this.isStreaming = false;
      this.pendingUserMessage = null;
    }
  }

  cancelGeneration(): void {
    if (!this.isStreaming) return;
    this.#streamController?.abort();
    this.#streamController = null;
    this.isStreaming = false;

    // Finalize whatever we have so far as a partial message
    if (this.streaming.textBuffer || this.streaming.thinkingBuffer) {
      this.#finalizeStream();
    } else {
      this.pendingUserMessage = null;
      this.streaming = { textBuffer: "", thinkingBuffer: "", toolCalls: [] };
    }
  }

  // ── Private ─────────────────────────────────────────────────────────────────

  #handleStreamEvent(event: StreamEvent): void {
    // Notify raw listeners first so they see the full event shape
    for (const fn of this.#streamListeners) {
      fn(event);
    }

    switch (event.type) {
      case "streaming_token":
        this.streaming.textBuffer += event.delta;
        break;

      case "thinking_delta":
        this.streaming.thinkingBuffer += event.delta;
        break;

      case "tool_call":
        this.streaming.toolCalls = [
          ...this.streaming.toolCalls,
          {
            id: event.tool_use_id,
            name: event.tool_name,
            input: event.input,
          },
        ];
        break;

      case "tool_result": {
        // Attach result to the matching tool call
        this.streaming.toolCalls = this.streaming.toolCalls.map((tc) =>
          tc.id === event.tool_use_id ? { ...tc, result: event.result } : tc,
        );
        break;
      }

      case "system_event":
        // Forward to consumers if needed — no-op in base store
        break;

      case "done":
        // Handled by onDone callback
        break;

      case "error":
        this.error = event.message;
        this.isStreaming = false;
        this.#streamController = null;
        break;
    }
  }

  #finalizeStream(): void {
    if (!this.currentSession) return;

    // Confirm the optimistic user message by moving it into messages
    if (this.pendingUserMessage) {
      this.messages = [...this.messages, this.pendingUserMessage];
      this.pendingUserMessage = null;
    }

    // Append the completed assistant message
    if (this.streaming.textBuffer || this.streaming.toolCalls.length > 0) {
      const assistantMessage: Message = {
        id: `assistant-${Date.now()}`,
        role: "assistant",
        content: this.streaming.textBuffer,
        timestamp: new Date().toISOString(),
        tool_calls:
          this.streaming.toolCalls.length > 0
            ? [...this.streaming.toolCalls]
            : undefined,
        thinking: this.streaming.thinkingBuffer
          ? { type: "thinking", thinking: this.streaming.thinkingBuffer }
          : undefined,
      };
      this.messages = [...this.messages, assistantMessage];
    }

    // Clear streaming buffers
    this.streaming = { textBuffer: "", thinkingBuffer: "", toolCalls: [] };
    this.isStreaming = false;
    this.#streamController = null;
  }
}

// ── Singleton Export ──────────────────────────────────────────────────────────

export const chatStore = new ChatStore();
