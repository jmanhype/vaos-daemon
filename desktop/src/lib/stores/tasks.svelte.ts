// src/lib/stores/tasks.svelte.ts
// Task tracking store — Svelte 5 class with $state fields.
// Manages orchestrator progress tasks, SSE-driven updates.

// ── Types ──────────────────────────────────────────────────────────────────────

export type TaskStatus = "pending" | "active" | "completed" | "failed";

export interface Task {
  id: string;
  text: string;
  status: TaskStatus;
  /** ISO timestamp when the task was created */
  createdAt: string;
  /** ISO timestamp when the task reached a terminal state */
  completedAt?: string;
}

// SSE event shapes emitted by the orchestrator
interface TaskCreatedEvent {
  type: "task_created";
  task_id: string;
  text: string;
}

interface TaskUpdatedEvent {
  type: "task_updated";
  task_id: string;
  status: TaskStatus;
}

export type TaskEvent = TaskCreatedEvent | TaskUpdatedEvent;

// ── TaskStore Class ──────────────────────────────────────────────────────────

class TaskStore {
  tasks = $state<Task[]>([]);

  // ── Derived ─────────────────────────────────────────────────────────────────

  completedCount = $derived(
    this.tasks.filter((t) => t.status === "completed").length,
  );

  activeTask = $derived(this.tasks.find((t) => t.status === "active") ?? null);

  hasTasks = $derived(this.tasks.length > 0);

  /** Tasks that are not yet in a terminal state */
  pendingTasks = $derived(
    this.tasks.filter((t) => t.status === "pending" || t.status === "active"),
  );

  // ── Mutations ────────────────────────────────────────────────────────────────

  addTask(id: string, text: string): void {
    // Avoid duplicates from replay
    if (this.tasks.some((t) => t.id === id)) return;
    this.tasks = [
      ...this.tasks,
      {
        id,
        text,
        status: "pending",
        createdAt: new Date().toISOString(),
      },
    ];
  }

  updateTask(id: string, status: TaskStatus): void {
    this.tasks = this.tasks.map((t) => {
      if (t.id !== id) return t;
      const isTerminal = status === "completed" || status === "failed";
      return {
        ...t,
        status,
        completedAt: isTerminal ? new Date().toISOString() : t.completedAt,
      };
    });
  }

  completeTask(id: string): void {
    this.updateTask(id, "completed");
  }

  failTask(id: string): void {
    this.updateTask(id, "failed");
  }

  /** Mark the next pending task as active (called by orchestrator on task start) */
  activateTask(id: string): void {
    this.updateTask(id, "active");
  }

  /** Clear all tasks — call when starting a fresh session */
  reset(): void {
    this.tasks = [];
  }

  // ── SSE integration ──────────────────────────────────────────────────────────

  /** Handle a raw task event from the SSE stream */
  handleEvent(event: TaskEvent): void {
    switch (event.type) {
      case "task_created":
        this.addTask(event.task_id, event.text);
        break;
      case "task_updated":
        this.updateTask(event.task_id, event.status);
        break;
    }
  }
}

// ── Singleton Export ──────────────────────────────────────────────────────────

export const taskStore = new TaskStore();
