// src/lib/stores/chat.svelte.ts
// Chat store — Svelte 5 class with $state fields.
// Manages sessions, messages, and the active stream lifecycle.

import type { Message, Session, StreamEvent, ToolCallRef } from "$api/types";
import { sessions as sessionsApi } from "$api/client";
import { streamMessage, type StreamController } from "$api/sse";

const BASE = "http://127.0.0.1:9089/api/v1";

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

  // Private — not reactive
  #streamController: StreamController | null = null;
  #pollAborted = false;

  /**
   * Raw event listeners — called for every SSE event before the store
   * processes it.
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
      const res = await fetch(`${BASE}/sessions`);
      if (res.ok) {
        const data = await res.json() as { sessions?: Session[] };
        this.sessions = data.sessions ?? [];
      }
    } catch (e) {
      const msg = (e as Error).message ?? String(e);
      this.error = msg;
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
      const [sessionRes, msgsRes] = await Promise.all([
        fetch(`${BASE}/sessions/${sessionId}`),
        fetch(`${BASE}/sessions/${sessionId}/messages`),
      ]);

      if (!sessionRes.ok) {
        this.currentSession = null;
        this.messages = [];
        this.isLoadingMessages = false;
        return;
      }

      const session = (await sessionRes.json()) as Session;
      const msgsData = msgsRes.ok
        ? ((await msgsRes.json()) as { messages?: Message[] })
        : { messages: [] };

      this.currentSession = session;
      this.messages = msgsData.messages ?? [];
      this.pendingUserMessage = null;
    } catch (e) {
      this.error = (e as Error).message ?? String(e);
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

    // Show user message immediately
    this.pendingUserMessage = {
      id: `msg-${Date.now()}`,
      role: "user",
      content,
      timestamp: new Date().toISOString(),
    };

    this.isStreaming = true;
    this.#pollAborted = false;

    // Try SSE streaming first; fall back to polling if stream endpoint fails
    const usedSessionId = sessionId;
    let sseSucceeded = false;

    try {
      // Attempt SSE stream
      this.#streamController = streamMessage({
        sessionId: usedSessionId,
        content,
        model,
        onEvent: (event: StreamEvent) => {
          sseSucceeded = true;
          this.#handleStreamEvent(event);
        },
        onConnect: () => {
          this.error = null;
        },
        onDisconnect: () => {
          // If SSE closed but we never got a done event, fall through to polling
          if (this.isStreaming && !sseSucceeded) {
            void this.#pollForResponse(usedSessionId);
          }
        },
        onError: () => {
          // SSE failed — fall back to polling
          if (this.isStreaming) {
            void this.#pollForResponse(usedSessionId);
          }
        },
        onDone: () => {
          this.#finalizeStream();
        },
      });
    } catch {
      // Sync error starting SSE — go straight to polling
      void this.#pollForResponse(usedSessionId);
    }
  }

  /**
   * Simple polling fallback: POST message then poll for assistant response.
   */
  async #pollForResponse(sessionId: string): Promise<void> {
    // First POST the message
    try {
      await fetch(`${BASE}/sessions/${sessionId}/message`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: this.pendingUserMessage?.content ?? "" }),
      });
    } catch (e) {
      this.error = (e as Error).message;
      this.isStreaming = false;
      this.pendingUserMessage = null;
      return;
    }

    // Poll up to 30 times (60s) for an assistant message
    const maxPolls = 30;
    for (let i = 0; i < maxPolls; i++) {
      await new Promise<void>((r) => setTimeout(r, 2000));
      if (!this.isStreaming || this.#pollAborted) return;

      try {
        const res = await fetch(`${BASE}/sessions/${sessionId}/messages`);
        if (!res.ok) continue;
        const data = (await res.json()) as { messages?: Message[] };
        const msgs = data.messages ?? [];
        const lastMsg = msgs[msgs.length - 1];
        if (lastMsg?.role === "assistant") {
          this.messages = msgs;
          this.isStreaming = false;
          this.pendingUserMessage = null;
          this.streaming = { textBuffer: "", thinkingBuffer: "", toolCalls: [] };
          return;
        }
      } catch {
        // Network hiccup — keep polling
      }
    }

    // Timeout — surface the pending message and stop
    if (this.pendingUserMessage) {
      this.messages = [...this.messages, this.pendingUserMessage];
      this.pendingUserMessage = null;
    }
    this.isStreaming = false;
    this.error = "Response timed out";
  }

  cancelGeneration(): void {
    if (!this.isStreaming) return;
    this.#pollAborted = true;
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
        this.streaming.toolCalls = this.streaming.toolCalls.map((tc) =>
          tc.id === event.tool_use_id ? { ...tc, result: event.result } : tc,
        );
        break;
      }

      case "system_event":
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
