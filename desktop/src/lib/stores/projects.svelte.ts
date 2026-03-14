// src/lib/stores/projects.svelte.ts
// Projects store — Svelte 5 class with $state fields.
// Manages projects, goal trees, and task links via the OSA backend,
// with mock fallback when the backend is unreachable.

import { projects as projectsApi } from "$lib/api/client";
import type {
  CreateGoalPayload,
  CreateProjectPayload,
  Goal,
  GoalTreeNode,
  Project,
  ProjectTask,
} from "$lib/api/types";

// Re-export for convenience so consumers only need one import.
export type { CreateGoalPayload, CreateProjectPayload };
export type { Goal, GoalTreeNode, Project, ProjectTask };

// ── Mock data (used when the backend is unreachable) ──────────────────────────

const MOCK_PROJECTS: Project[] = [
  {
    id: 1,
    name: "OSA Desktop App",
    description: "Tauri + SvelteKit desktop application for OSA",
    goal: "Ship a polished v1.0 release with full agent orchestration",
    status: "active",
    workspace_path: "~/Desktop/OSAMain/OSA/desktop",
    slug: "osa-desktop-app",
    metadata: {},
    inserted_at: new Date(Date.now() - 86_400_000 * 30).toISOString(),
    updated_at: new Date(Date.now() - 3_600_000).toISOString(),
  },
  {
    id: 2,
    name: "API Gateway",
    description: "Elixir Phoenix backend for agent orchestration",
    goal: "Achieve 99.9% uptime and sub-100ms P99 latency",
    status: "active",
    workspace_path: "~/Desktop/OSAMain/OSA/backend",
    slug: "api-gateway",
    metadata: {},
    inserted_at: new Date(Date.now() - 86_400_000 * 60).toISOString(),
    updated_at: new Date(Date.now() - 86_400_000 * 2).toISOString(),
  },
  {
    id: 3,
    name: "Agent Memory System",
    description: "Persistent vector-backed memory for OSA agents",
    goal: "Enable agents to recall context across sessions reliably",
    status: "completed",
    workspace_path: "~/Desktop/OSAMain/OSA/memory",
    slug: "agent-memory-system",
    metadata: {},
    inserted_at: new Date(Date.now() - 86_400_000 * 90).toISOString(),
    updated_at: new Date(Date.now() - 86_400_000 * 10).toISOString(),
  },
];

const MOCK_GOALS: GoalTreeNode[] = [
  {
    id: 1,
    project_id: 1,
    parent_id: null,
    title: "Ship v1.0 release",
    description: null,
    status: "in_progress",
    priority: "high",
    task_count: 4,
    metadata: {},
    inserted_at: new Date(Date.now() - 86_400_000 * 10).toISOString(),
    updated_at: new Date(Date.now() - 86_400_000 * 2).toISOString(),
    children: [
      {
        id: 2,
        project_id: 1,
        parent_id: 1,
        title: "Complete Projects page UI",
        description: null,
        status: "in_progress",
        priority: "high",
        task_count: 2,
        metadata: {},
        inserted_at: new Date(Date.now() - 86_400_000 * 5).toISOString(),
        updated_at: new Date(Date.now() - 86_400_000).toISOString(),
        children: [],
      },
      {
        id: 3,
        project_id: 1,
        parent_id: 1,
        title: "Write integration tests",
        description: null,
        status: "active",
        priority: "medium",
        task_count: 1,
        metadata: {},
        inserted_at: new Date(Date.now() - 86_400_000 * 4).toISOString(),
        updated_at: new Date(Date.now() - 86_400_000).toISOString(),
        children: [],
      },
    ],
  },
  {
    id: 4,
    project_id: 1,
    parent_id: null,
    title: "Improve developer onboarding",
    description: null,
    status: "active",
    priority: "medium",
    task_count: 3,
    metadata: {},
    inserted_at: new Date(Date.now() - 86_400_000 * 7).toISOString(),
    updated_at: new Date(Date.now() - 86_400_000 * 3).toISOString(),
    children: [],
  },
];

// ── ProjectsStore Class ───────────────────────────────────────────────────────

class ProjectsStore {
  // ── List state ────────────────────────────────────────────────────────────────

  projects = $state<Project[]>([]);
  loading = $state(false);
  error = $state<string | null>(null);

  // ── Selection state ───────────────────────────────────────────────────────────

  selectedProject = $state<Project | null>(null);
  goals = $state<GoalTreeNode[]>([]);
  projectTasks = $state<ProjectTask[]>([]);
  goalsLoading = $state(false);
  tasksLoading = $state(false);

  // ── Derived ──────────────────────────────────────────────────────────────────

  activeCount = $derived(
    this.projects.filter((p) => p.status === "active").length,
  );

  completedCount = $derived(
    this.projects.filter((p) => p.status === "completed").length,
  );

  archivedCount = $derived(
    this.projects.filter((p) => p.status === "archived").length,
  );

  /** Flat depth-first list of all goals in the current goal tree. */
  flatGoals = $derived(flattenTree(this.goals));

  // ── List actions ──────────────────────────────────────────────────────────────

  async fetchProjects(): Promise<void> {
    this.loading = true;
    this.error = null;
    try {
      this.projects = await projectsApi.list();
    } catch {
      this.projects = [...MOCK_PROJECTS];
    } finally {
      this.loading = false;
    }
  }

  async createProject(payload: CreateProjectPayload): Promise<Project | null> {
    this.error = null;
    try {
      const project = await projectsApi.create(payload);
      this.projects = [project, ...this.projects];
      return project;
    } catch (e) {
      this.error = e instanceof Error ? e.message : "Failed to create project";
      return null;
    }
  }

  async updateProject(
    id: number,
    payload: Partial<CreateProjectPayload>,
  ): Promise<void> {
    this.error = null;
    try {
      const updated = await projectsApi.update(id, payload);
      this.projects = this.projects.map((p) => (p.id === id ? updated : p));
      if (this.selectedProject?.id === id) {
        this.selectedProject = updated;
      }
    } catch (e) {
      this.error = e instanceof Error ? e.message : "Failed to update project";
    }
  }

  /** Optimistically removes the project then calls the archive endpoint. */
  async archiveProject(id: number): Promise<void> {
    const previous = this.projects;
    this.projects = this.projects.filter((p) => p.id !== id);
    if (this.selectedProject?.id === id) {
      this.clearSelection();
    }
    try {
      await projectsApi.archive(id);
    } catch {
      this.projects = previous;
    }
  }

  // ── Selection actions ─────────────────────────────────────────────────────────

  /**
   * Sets the selected project and concurrently fetches its goals and tasks.
   * If the project is already present in the list it is used immediately
   * without an extra round-trip.
   */
  async selectProject(id: number): Promise<void> {
    this.selectedProject = this.projects.find((p) => p.id === id) ?? null;
    this.goals = [];
    this.projectTasks = [];

    if (this.selectedProject) {
      await Promise.all([this.fetchGoals(id), this.fetchProjectTasks(id)]);
    }
  }

  clearSelection(): void {
    this.selectedProject = null;
    this.goals = [];
    this.projectTasks = [];
  }

  // ── Goal actions ──────────────────────────────────────────────────────────────

  async fetchGoals(projectId: number): Promise<void> {
    this.goalsLoading = true;
    try {
      const raw = await projectsApi.goals(projectId);
      this.goals = mapGoalTree(raw as unknown as ApiGoalTreeNode[]);
    } catch {
      this.goals = projectId === 1 ? [...MOCK_GOALS] : [];
    } finally {
      this.goalsLoading = false;
    }
  }

  async createGoal(
    projectId: number,
    payload: CreateGoalPayload,
  ): Promise<Goal | null> {
    this.error = null;
    try {
      const goal = await projectsApi.createGoal(projectId, payload);
      // Re-fetch the full tree so parent/child relationships stay correct.
      await this.fetchGoals(projectId);
      return goal;
    } catch (e) {
      this.error = e instanceof Error ? e.message : "Failed to create goal";
      return null;
    }
  }

  async updateGoal(
    projectId: number,
    goalId: number,
    payload: Partial<CreateGoalPayload>,
  ): Promise<void> {
    this.error = null;
    try {
      await projectsApi.updateGoal(projectId, goalId, payload);
      await this.fetchGoals(projectId);
    } catch (e) {
      this.error = e instanceof Error ? e.message : "Failed to update goal";
    }
  }

  async deleteGoal(projectId: number, goalId: number): Promise<void> {
    this.error = null;
    try {
      await projectsApi.deleteGoal(projectId, goalId);
      await this.fetchGoals(projectId);
    } catch (e) {
      this.error = e instanceof Error ? e.message : "Failed to delete goal";
    }
  }

  // ── Task-link actions ─────────────────────────────────────────────────────────

  async fetchProjectTasks(projectId: number): Promise<void> {
    this.tasksLoading = true;
    try {
      this.projectTasks = await projectsApi.tasks(projectId);
    } catch {
      this.projectTasks = [];
    } finally {
      this.tasksLoading = false;
    }
  }

  async linkTask(
    projectId: number,
    taskId: string,
    goalId?: number,
  ): Promise<void> {
    this.error = null;
    try {
      await projectsApi.linkTask(projectId, taskId, goalId);
      await this.fetchProjectTasks(projectId);
    } catch (e) {
      this.error = e instanceof Error ? e.message : "Failed to link task";
    }
  }

  /** Optimistically removes the link then calls the unlink endpoint. */
  async unlinkTask(projectId: number, taskId: string): Promise<void> {
    const previous = this.projectTasks;
    this.projectTasks = this.projectTasks.filter((t) => t.task_id !== taskId);
    try {
      await projectsApi.unlinkTask(projectId, taskId);
    } catch {
      this.projectTasks = previous;
    }
  }

  // ── Utility ───────────────────────────────────────────────────────────────────

  clearError(): void {
    this.error = null;
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function flattenTree(nodes: GoalTreeNode[]): Goal[] {
  const result: Goal[] = [];
  for (const node of nodes) {
    result.push(node);
    result.push(...flattenTree(node.children));
  }
  return result;
}

interface ApiGoalTreeNode {
  goal: Goal;
  children: ApiGoalTreeNode[];
}

function mapGoalTree(nodes: ApiGoalTreeNode[]): GoalTreeNode[] {
  return nodes.map((n) => ({
    ...n.goal,
    children: mapGoalTree(n.children),
  }));
}

// ── Singleton Export ──────────────────────────────────────────────────────────

export const projectsStore = new ProjectsStore();
