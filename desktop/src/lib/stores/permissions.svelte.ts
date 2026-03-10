// src/lib/stores/permissions.svelte.ts
// Permission request queue for agent tool execution.
// Supports promise-based resolution, always-allow tracking, and YOLO mode.

// ── Types ─────────────────────────────────────────────────────────────────────

export type PermissionDecision = "allow" | "allow_always" | "deny";

export interface PermissionRequest {
  /** Unique ID for this request */
  id: string;
  /** Tool name, e.g. "bash", "read_file", "write_file" */
  tool: string;
  /** Human-readable explanation of what the tool will do */
  description: string;
  /** File paths, globs, or other arguments to display */
  paths: string[];
  /** Resolve the pending promise */
  resolve: (decision: PermissionDecision) => void;
}

// ── Permission Store ──────────────────────────────────────────────────────────

class PermissionStore {
  // Queue of pending requests — only the first is shown at a time
  queue = $state<PermissionRequest[]>([]);

  // Tools that have been granted "allow always" in this session
  #alwaysAllowed = new Set<string>();

  // YOLO mode: auto-approve everything without showing dialog
  yolo = $state(false);

  // ── Derived ─────────────────────────────────────────────────────────────────

  /** The request currently shown to the user (head of queue) */
  get current(): PermissionRequest | null {
    return this.queue[0] ?? null;
  }

  /** True when there is at least one pending request */
  get hasPending(): boolean {
    return this.queue.length > 0;
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /**
   * Request permission for a tool call.
   *
   * Resolves immediately with 'allow' if:
   *   - YOLO mode is active
   *   - The tool has been granted "allow always" this session
   *
   * Otherwise queues the request and waits for user input.
   */
  requestPermission(
    tool: string,
    description: string,
    paths: string[] = [],
  ): Promise<PermissionDecision> {
    // Fast paths — no dialog required
    if (this.yolo) return Promise.resolve("allow");
    if (this.#alwaysAllowed.has(tool)) return Promise.resolve("allow");

    return new Promise<PermissionDecision>((resolve) => {
      const request: PermissionRequest = {
        id: `perm-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
        tool,
        description,
        paths,
        resolve,
      };
      this.queue = [...this.queue, request];
    });
  }

  /**
   * Resolve the current (head) request with a decision.
   * Removes it from the queue after resolution.
   */
  decide(decision: PermissionDecision): void {
    const current = this.queue[0];
    if (!current) return;

    if (decision === "allow_always") {
      this.#alwaysAllowed.add(current.tool);
    }

    current.resolve(decision);
    this.queue = this.queue.slice(1);
  }

  /** Convenience wrappers */
  allow(): void {
    this.decide("allow");
  }
  allowAlways(): void {
    this.decide("allow_always");
  }
  deny(): void {
    this.decide("deny");
  }

  /** Enable YOLO mode — resolves all queued requests immediately */
  enableYolo(): void {
    this.yolo = true;
    // Drain the current queue
    for (const req of this.queue) {
      req.resolve("allow");
    }
    this.queue = [];
  }

  disableYolo(): void {
    this.yolo = false;
  }

  /** Check if a tool is in the always-allowed set */
  isAlwaysAllowed(tool: string): boolean {
    return this.#alwaysAllowed.has(tool);
  }

  /** Clear always-allowed grants (e.g. on session end) */
  clearAlwaysAllowed(): void {
    this.#alwaysAllowed.clear();
  }

  /**
   * Handle an SSE tool_call event that arrives with phase: "awaiting_permission".
   * Wraps requestPermission in a fire-and-forget manner, returning the decision
   * via a callback so the SSE consumer can POST the response to the backend.
   */
  handleToolCallEvent(
    tool: string,
    description: string,
    paths: string[],
    onDecision: (decision: PermissionDecision) => void,
  ): void {
    this.requestPermission(tool, description, paths).then(onDecision);
  }
}

// ── Singleton Export ──────────────────────────────────────────────────────────

export const permissionStore = new PermissionStore();
