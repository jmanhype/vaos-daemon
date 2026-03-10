// src/lib/api/sse.ts
// fetch-based SSE client.
// Uses fetch (not EventSource) for POST support and Authorization header control.

import type { StreamEvent } from "./types";
import { getToken } from "./client";

const BASE_URL = "http://127.0.0.1:8089";
const API_PREFIX = "/api/v1";

// ── Back-off Constants ────────────────────────────────────────────────────────

const INITIAL_DELAY_MS = 1_000;
const MAX_DELAY_MS = 30_000;
const BACKOFF_FACTOR = 2;

// ── Typed Callbacks ───────────────────────────────────────────────────────────

export interface SSECallbacks {
  onEvent: (event: StreamEvent) => void;
  onConnect?: () => void;
  onDisconnect?: () => void;
  onError?: (error: Error) => void;
  onDone?: () => void;
}

export interface StreamController {
  abort: () => void;
}

// ── SSE Line Parser ───────────────────────────────────────────────────────────

/**
 * Parse a raw SSE message block (delimited by \n\n) into typed StreamEvents.
 * Handles multi-line messages and strips "data: " prefixes.
 * Returns null for keep-alive or comment-only blocks.
 */
function parseSSEBlock(block: string): StreamEvent | null {
  const lines = block.split("\n");
  let data = "";

  for (const line of lines) {
    if (line.startsWith("data: ")) {
      data = line.slice("data: ".length).trim();
    }
    // ignore id:, event:, retry: lines for now
  }

  if (!data || data === "[DONE]") return null;

  try {
    return JSON.parse(data) as StreamEvent;
  } catch {
    return null;
  }
}

// ── Stream Reader ─────────────────────────────────────────────────────────────

async function consumeStream(
  response: Response,
  callbacks: SSECallbacks,
  signal: AbortSignal,
): Promise<void> {
  if (!response.body) throw new Error("Response body is null");

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  callbacks.onConnect?.();

  try {
    while (true) {
      if (signal.aborted) break;

      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });

      // SSE messages are delimited by double newlines
      const blocks = buffer.split("\n\n");
      // Keep the last (potentially incomplete) block in the buffer
      buffer = blocks.pop() ?? "";

      for (const block of blocks) {
        if (!block.trim()) continue;

        const event = parseSSEBlock(block);
        if (!event) continue;

        callbacks.onEvent(event);

        if (event.type === "done") {
          callbacks.onDone?.();
          return;
        }
        if (event.type === "error") {
          callbacks.onError?.(new Error(event.message));
          return;
        }
      }
    }
  } finally {
    reader.cancel().catch(() => undefined);
    callbacks.onDisconnect?.();
  }
}

// ── Chat Message Stream ───────────────────────────────────────────────────────

export interface ChatStreamOptions extends SSECallbacks {
  sessionId: string;
  content: string;
  model?: string;
}

/**
 * POST a chat message and stream the response.
 * Returns a controller with abort() for cancellation.
 *
 * Protocol: POST /api/v1/messages/stream → text/event-stream
 */
export function streamMessage(options: ChatStreamOptions): StreamController {
  const controller = new AbortController();
  const { signal } = controller;

  (async () => {
    const token = getToken();
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      Accept: "text/event-stream",
      "Cache-Control": "no-cache",
      "X-Accel-Buffering": "no",
    };
    if (token) headers["Authorization"] = `Bearer ${token}`;

    try {
      const response = await fetch(`${BASE_URL}${API_PREFIX}/messages/stream`, {
        method: "POST",
        headers,
        body: JSON.stringify({
          session_id: options.sessionId,
          content: options.content,
          model: options.model,
          stream: true,
        }),
        signal,
      });

      if (!response.ok) {
        const body = await response.text().catch(() => "");
        throw new Error(`HTTP ${response.status}: ${body}`);
      }

      await consumeStream(response, options, signal);
    } catch (error) {
      if ((error as Error).name === "AbortError") return;
      options.onError?.(error as Error);
    }
  })();

  return { abort: () => controller.abort() };
}

// ── Agent Event Stream (long-lived, auto-reconnect) ───────────────────────────

/**
 * Subscribe to the agent status SSE stream.
 * Reconnects automatically with exponential back-off on disconnect.
 * Pass the AbortSignal from a parent AbortController to stop cleanly.
 *
 * Protocol: GET /api/v1/agents/stream → text/event-stream
 */
export function subscribeToAgentEvents(
  callbacks: SSECallbacks,
  signal: AbortSignal,
): void {
  let delayMs = INITIAL_DELAY_MS;

  const connect = async (): Promise<void> => {
    if (signal.aborted) return;

    const token = getToken();
    const headers: Record<string, string> = {
      Accept: "text/event-stream",
      "Cache-Control": "no-cache",
    };
    if (token) headers["Authorization"] = `Bearer ${token}`;

    try {
      const response = await fetch(`${BASE_URL}${API_PREFIX}/agents/stream`, {
        headers,
        signal,
      });

      if (!response.ok || !response.body) {
        throw new Error(`HTTP ${response.status}`);
      }

      // Successful connection — reset backoff
      delayMs = INITIAL_DELAY_MS;

      await consumeStream(response, callbacks, signal);
    } catch (error) {
      if ((error as Error).name === "AbortError") return;
      callbacks.onError?.(error as Error);
    }

    if (!signal.aborted) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, delayMs);
        signal.addEventListener(
          "abort",
          () => {
            clearTimeout(timer);
            resolve();
          },
          { once: true },
        );
      });
      delayMs = Math.min(delayMs * BACKOFF_FACTOR, MAX_DELAY_MS);
      connect();
    }
  };

  connect();
}

// ── Generic GET SSE Stream (reconnecting) ────────────────────────────────────

/**
 * Subscribe to any GET-based SSE endpoint with automatic reconnection.
 * Returns a StreamController for manual cancellation.
 */
export function connectSSE(
  path: string,
  callbacks: SSECallbacks,
  maxAttempts = 5,
): StreamController {
  const outer = new AbortController();
  const { signal } = outer;
  let attempt = 0;
  let delayMs = INITIAL_DELAY_MS;

  const connect = async (): Promise<void> => {
    if (signal.aborted) return;

    const token = getToken();
    const headers: Record<string, string> = {
      Accept: "text/event-stream",
      "Cache-Control": "no-cache",
    };
    if (token) headers["Authorization"] = `Bearer ${token}`;

    try {
      const response = await fetch(`${BASE_URL}${API_PREFIX}${path}`, {
        headers,
        signal,
      });

      if (!response.ok) throw new Error(`HTTP ${response.status}`);

      attempt = 0;
      delayMs = INITIAL_DELAY_MS;

      await consumeStream(response, callbacks, signal);
    } catch (error) {
      if ((error as Error).name === "AbortError") return;

      callbacks.onDisconnect?.();

      if (attempt >= maxAttempts) {
        callbacks.onError?.(
          new Error(`SSE: max reconnect attempts (${maxAttempts}) exceeded`),
        );
        return;
      }
    }

    if (!signal.aborted) {
      attempt++;
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, delayMs);
        signal.addEventListener(
          "abort",
          () => {
            clearTimeout(timer);
            resolve();
          },
          { once: true },
        );
      });
      delayMs = Math.min(delayMs * BACKOFF_FACTOR, MAX_DELAY_MS);
      connect();
    }
  };

  connect();

  return { abort: () => outer.abort() };
}
