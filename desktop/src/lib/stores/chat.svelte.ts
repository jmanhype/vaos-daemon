// src/lib/stores/chat.svelte.ts
// Chat store — Svelte 5 class with $state fields.
// Manages sessions, messages, and the active SSE stream lifecycle.

import type { Message, Session, StreamEvent, ToolCallRef } from "$api/types";
import { messages as messagesApi, sessions as sessionsApi } from "$api/client";
import { streamMessage, type StreamController } from "$api/sse";

// ── Types ──────────────────────────────────────────────────────────────────────

/**
 * A tool call entry while streaming — extends ToolCallRef with live result/error
 * fields that are filled in as tool_result events arrive.
 */
export interface StreamingToolCall extends ToolCallRef {
  result?: string;
  isError?: boolean;
}

export interface StreamingMessage {
  /** Incremental text buffer during streaming */
  textBuffer: string;
  /** Incremental thinking buffer during streaming */
  thinkingBuffer: string;
  /** Tool calls accumulated during this stream (with live result state) */
  toolCalls: StreamingToolCall[];
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
      // Only surface connectivity errors — not API-level issues
      const msg = (e as Error).message ?? String(e);
      if (
        msg.includes("fetch") ||
        msg.includes("network") ||
        msg.includes("Failed")
      ) {
        this.error = msg;
      }
    } finally {
      this.isLoadingSessions = false;
    }
  }

  async createSession(title?: string, model?: string): Promise<Session> {
    const result = await sessionsApi.create({ title, model });
    // Backend returns { id, status } — construct a Session object
    const session: Session = {
      id: result.id,
      title: title ?? null,
      created_at: new Date().toISOString(),
      message_count: 0,
      alive: true,
    };
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
      const err = e as { status?: number; message?: string };
      // Distinguish API errors (session not found = 404/500) from
      // real connectivity failures (fetch throws TypeError).
      if (err.status !== undefined) {
        // Got a response from the server — it's online, just session issue
        this.currentSession = null;
        this.messages = [];
      } else {
        // Network-level failure — backend truly offline
        this.error = err.message ?? String(e);
      }
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
      // Open the SSE stream (which POSTs the message and streams the response)
      // Note: we do NOT call messagesApi.send() separately — the stream endpoint
      // handles both receiving the message and streaming the response.
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

      // Polling fallback: if SSE doesn't deliver the response within 8s,
      // poll the messages API to get the response directly.
      // This handles cases where SSE streaming fails silently.
      setTimeout(async () => {
        if (this.isStreaming && this.streaming.textBuffer.length === 0 && sessionId) {
          console.log("[chat] SSE timeout — polling for response");
          try {
            const msgs = await messagesApi.list(sessionId);
            const assistantMsg = msgs.filter(m => m.role === "assistant").pop();
            if (assistantMsg) {
              this.streaming.textBuffer = assistantMsg.content;
              this.#finalizeStream();
            }
          } catch {
            // Poll failed — will retry
          }

          // Retry once more after another 8s
          setTimeout(async () => {
            if (this.isStreaming && this.streaming.textBuffer.length === 0 && sessionId) {
              console.log("[chat] SSE timeout — second poll");
              try {
                const msgs = await messagesApi.list(sessionId);
                const assistantMsg = msgs.filter(m => m.role === "assistant").pop();
                if (assistantMsg) {
                  this.streaming.textBuffer = assistantMsg.content;
                  this.#finalizeStream();
                }
              } catch {
                this.isStreaming = false;
                this.error = "No response received";
              }
            }
          }, 8000);
        }
      }, 8000);
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
        // Attach result and error flag to the matching tool call
        this.streaming.toolCalls = this.streaming.toolCalls.map((tc) =>
          tc.id === event.tool_use_id
            ? { ...tc, result: event.result, isError: event.is_error }
            : tc,
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
