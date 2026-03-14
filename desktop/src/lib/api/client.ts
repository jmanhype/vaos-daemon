// src/lib/api/client.ts
// HTTP API client for the OSA backend at localhost:9089/api/v1

import { load as loadStore } from "@tauri-apps/plugin-store";
import type {
  Agent,
  CreateSessionRequest,
  CreateSessionResponse,
  HealthResponse,
  Message,
  Model,
  OnboardingStatus,
  OrchestrateRequest,
  OrchestrateResponse,
  Provider,
  SendMessageRequest,
  SendMessageResponse,
  Session,
  Settings,
  Skill,
  SkillCategoryCount,
  SkillDetail,
  SkillSearchResult,
} from "./types";

// ── Configuration ─────────────────────────────────────────────────────────────

export const BASE_URL = "http://127.0.0.1:9089";
export const API_PREFIX = "/api/v1";

// ── Token Store ───────────────────────────────────────────────────────────────

let _token: string | null = null;
let _refreshPromise: Promise<string | null> | null = null;
let _refreshTimerId: ReturnType<typeof setInterval> | null = null;

export function getToken(): string | null {
  return _token;
}

export function setToken(token: string | null): void {
  _token = token;
}

// ── Auth Initialization ───────────────────────────────────────────────────────

/**
 * Initializes authentication by:
 * 1. Reading any previously stored token from the Tauri store
 * 2. If absent, logging in with an auto-generated user_id to obtain one
 * 3. Persisting the token and scheduling periodic refreshes
 *
 * Call once from the root layout onMount.
 */
export async function initializeAuth(): Promise<void> {
  // Step 1: Try to recover a previously stored token
  try {
    const store = await loadStore("store.json", {
      autoSave: true,
      defaults: {},
    });
    const stored = await store.get<string>("authToken");
    if (stored) {
      _token = stored;
    }
  } catch {
    // Tauri store unavailable (e.g. running in browser dev mode) — proceed to login
  }

  // Step 2: If no token, login to obtain one
  if (!_token) {
    try {
      const userId = crypto.randomUUID();
      const response = await fetch(`${BASE_URL}${API_PREFIX}/auth/login`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ user_id: userId }),
      });

      if (response.ok) {
        const data = (await response.json()) as { token: string };
        _token = data.token;

        // Persist for future sessions
        try {
          const store = await loadStore("store.json", {
            autoSave: true,
            defaults: {},
          });
          await store.set("authToken", _token);
          await store.save();
        } catch {
          // Non-fatal — token is in-memory for this session
        }
      }
    } catch {
      // Backend may not yet be ready — requests will proceed unauthenticated
      // and will auto-refresh on first 401
    }
  }

  // Step 3: Schedule token refresh every 10 minutes
  if (_refreshTimerId !== null) {
    clearInterval(_refreshTimerId);
  }
  _refreshTimerId = setInterval(
    () => {
      void refreshToken();
    },
    10 * 60 * 1000,
  );
}

// ── Typed Error ───────────────────────────────────────────────────────────────

export class ApiError extends Error {
  readonly status: number;
  readonly code: string | undefined;
  readonly body: unknown;

  constructor(status: number, message: string, body?: unknown) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code =
      typeof body === "object" && body !== null && "code" in body
        ? String((body as Record<string, unknown>).code)
        : undefined;
    this.body = body;
  }
}

// ── Token Refresh ─────────────────────────────────────────────────────────────

async function refreshToken(): Promise<string | null> {
  // De-duplicate concurrent refresh calls
  if (_refreshPromise) return _refreshPromise;

  _refreshPromise = (async () => {
    try {
      const response = await fetch(`${BASE_URL}${API_PREFIX}/auth/refresh`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
      });

      if (!response.ok) {
        _token = null;
        return null;
      }

      const data = (await response.json()) as { token: string };
      _token = data.token;
      return _token;
    } catch {
      _token = null;
      return null;
    } finally {
      _refreshPromise = null;
    }
  })();

  return _refreshPromise;
}

// ── Core Request ──────────────────────────────────────────────────────────────

async function request<T>(
  path: string,
  options: RequestInit = {},
  retried = false,
): Promise<T> {
  const url = `${BASE_URL}${API_PREFIX}${path}`;

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json",
    ...(options.headers as Record<string, string> | undefined),
  };

  if (_token) {
    headers["Authorization"] = `Bearer ${_token}`;
  }

  const response = await fetch(url, {
    ...options,
    headers,
  });

  // Auto-refresh on 401 — one retry only
  if (response.status === 401 && !retried) {
    const newToken = await refreshToken();
    if (newToken) {
      return request<T>(path, options, true);
    }
    // Refresh failed — surface the 401
  }

  if (!response.ok) {
    let body: unknown;
    try {
      body = await response.json();
    } catch {
      body = await response.text();
    }
    const message =
      typeof body === "object" && body !== null && "error" in body
        ? String((body as Record<string, unknown>).error)
        : `HTTP ${response.status}: ${path}`;
    throw new ApiError(response.status, message, body);
  }

  // 204 No Content
  if (response.status === 204) return undefined as T;

  return response.json() as Promise<T>;
}

// ── Health ────────────────────────────────────────────────────────────────────

export const health = {
  /** Health endpoint is at root level, not under /api/v1 */
  get: async (): Promise<HealthResponse> => {
    const res = await fetch(`${BASE_URL}/health`, {
      headers: { Accept: "application/json" },
    });
    if (!res.ok) throw new ApiError(res.status, "Health check failed");
    return res.json() as Promise<HealthResponse>;
  },
};

// ── Onboarding ────────────────────────────────────────────────────────────────

export const onboarding = {
  /** Onboarding endpoints are at root level, not under /api/v1 */
  status: async (): Promise<OnboardingStatus> => {
    const res = await fetch(`${BASE_URL}/onboarding/status`, {
      headers: { Accept: "application/json" },
    });
    if (!res.ok) throw new ApiError(res.status, "Onboarding status failed");
    return res.json() as Promise<OnboardingStatus>;
  },
  complete: async (): Promise<void> => {
    const res = await fetch(`${BASE_URL}/onboarding/complete`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
    });
    if (!res.ok) throw new ApiError(res.status, "Onboarding complete failed");
  },
};

// ── Sessions ──────────────────────────────────────────────────────────────────

export const sessions = {
  list: async (): Promise<Session[]> => {
    const data = await request<{ sessions: Session[]; count: number }>(
      "/sessions",
    );
    return data.sessions ?? [];
  },
  get: (id: string) => request<Session>(`/sessions/${id}`),
  create: (body: CreateSessionRequest = {}) =>
    request<CreateSessionResponse>("/sessions", {
      method: "POST",
      body: JSON.stringify(body),
    }),
  delete: (id: string) =>
    request<void>(`/sessions/${id}`, { method: "DELETE" }),
  rename: (id: string, title: string) =>
    request<Session>(`/sessions/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ title }),
    }),
};

// ── Messages ──────────────────────────────────────────────────────────────────

export const messages = {
  list: async (sessionId: string): Promise<Message[]> => {
    const data = await request<{ messages: Message[]; count: number }>(
      `/sessions/${sessionId}/messages`,
    );
    return data.messages ?? [];
  },

  /**
   * POST a message. Returns a stream_id for subscribing via SSE.
   * For full streaming, use sse.streamMessage() with the returned stream_id.
   */
  send: (body: SendMessageRequest) =>
    request<SendMessageResponse>("/messages", {
      method: "POST",
      body: JSON.stringify({ ...body, stream: true }),
    }),
};

// ── Models ────────────────────────────────────────────────────────────────────

export const models = {
  list: async (): Promise<Model[]> => {
    const data = await request<{
      models: Model[];
      current?: string;
      provider?: string;
    }>("/models");
    return data.models ?? [];
  },
  activate: (name: string) =>
    request<Model>(`/models/${encodeURIComponent(name)}/activate`, {
      method: "POST",
    }),
  download: (name: string) =>
    request<{ job_id: string }>(
      `/models/${encodeURIComponent(name)}/download`,
      {
        method: "POST",
      },
    ),
  delete: (name: string) =>
    request<void>(`/models/${encodeURIComponent(name)}`, { method: "DELETE" }),
};

// ── Providers ─────────────────────────────────────────────────────────────────

export const providers = {
  list: () => request<Provider[]>("/providers"),
  connect: (slug: string, apiKey: string) =>
    request<Provider>(`/providers/${slug}/connect`, {
      method: "POST",
      body: JSON.stringify({ api_key: apiKey }),
    }),
  disconnect: (slug: string) =>
    request<void>(`/providers/${slug}`, { method: "DELETE" }),
};

// ── Agents ────────────────────────────────────────────────────────────────────

export const agents = {
  list: () => request<Agent[]>("/agents"),
  get: (id: string) => request<Agent>(`/agents/${id}`),
  pause: (id: string) =>
    request<Agent>(`/agents/${id}/pause`, { method: "POST" }),
  resume: (id: string) =>
    request<Agent>(`/agents/${id}/resume`, { method: "POST" }),
  cancel: (id: string) => request<void>(`/agents/${id}`, { method: "DELETE" }),
};

// ── Orchestrate ───────────────────────────────────────────────────────────────

export const orchestrate = {
  run: (body: OrchestrateRequest) =>
    request<OrchestrateResponse>("/orchestrate", {
      method: "POST",
      body: JSON.stringify(body),
    }),
};

// ── Settings ──────────────────────────────────────────────────────────────────

export const settings = {
  get: () => request<Settings>("/settings"),
  update: (body: Partial<Settings>) =>
    request<Settings>("/settings", {
      method: "PATCH",
      body: JSON.stringify(body),
    }),
};

// ── Skills Marketplace ────────────────────────────────────────────────────────

export const skills = {
  list: async (): Promise<Skill[]> => {
    const data = await request<{ skills: Skill[]; count: number }>(
      "/skills/marketplace",
    );
    return data.skills ?? [];
  },
  get: (id: string) =>
    request<SkillDetail>(`/skills/marketplace/${encodeURIComponent(id)}`),
  toggle: (id: string) =>
    request<{ id: string; enabled: boolean }>(
      `/skills/marketplace/${encodeURIComponent(id)}/toggle`,
      { method: "PUT" },
    ),
  search: async (query: string): Promise<SkillSearchResult[]> => {
    const data = await request<{
      results: SkillSearchResult[];
      count: number;
    }>("/skills/marketplace/search", {
      method: "POST",
      body: JSON.stringify({ query }),
    });
    return data.results ?? [];
  },
  categories: async (): Promise<SkillCategoryCount[]> => {
    const data = await request<{ categories: SkillCategoryCount[] }>(
      "/skills/marketplace/categories",
    );
    return data.categories ?? [];
  },
  bulkEnable: (ids: string[]) =>
    request<{ enabled: string[]; count: number }>(
      "/skills/marketplace/bulk-enable",
      { method: "POST", body: JSON.stringify({ ids }) },
    ),
  bulkDisable: (ids: string[]) =>
    request<{ disabled: string[]; count: number }>(
      "/skills/marketplace/bulk-disable",
      { method: "POST", body: JSON.stringify({ ids }) },
    ),
};

// ── Scheduler ─────────────────────────────────────────────────────────────────

export const scheduler = {
  list: <T>() => request<T>("/scheduler/jobs"),
  get: <T>(id: string) => request<T>(`/scheduler/jobs/${id}`),
  create: <T>(body: unknown) =>
    request<T>("/scheduler/jobs", {
      method: "POST",
      body: JSON.stringify(body),
    }),
  delete: (id: string) =>
    request<void>(`/scheduler/jobs/${id}`, { method: "DELETE" }),
  toggle: <T>(id: string) =>
    request<T>(`/scheduler/jobs/${id}/toggle`, { method: "POST" }),
  runNow: <T>(id: string) =>
    request<T>(`/scheduler/jobs/${id}/run`, { method: "POST" }),
  runs: <T>(id: string, page = 1, limit = 20) =>
    request<T>(`/scheduler/jobs/${id}/runs?page=${page}&limit=${limit}`),
  run: <T>(taskId: string, runId: string) =>
    request<T>(`/scheduler/jobs/${taskId}/runs/${runId}`),
  presets: <T>() => request<T>("/scheduler/presets"),
};

// ── Costs ────────────────────────────────────────────────────────────────────

export const costs = {
  summary: () => request<CostSummary>("/costs"),
  byAgent: () => request<{ agents: CostByAgent[] }>("/costs/by-agent"),
  byModel: () => request<{ models: CostByModel[] }>("/costs/by-model"),
  events: (page = 1, perPage = 20, agentName?: string) => {
    const params = new URLSearchParams({
      page: String(page),
      per_page: String(perPage),
    });
    if (agentName) params.set("agent_name", agentName);
    return request<{ events: CostEvent[]; page: number; per_page: number }>(
      `/costs/events?${params}`,
    );
  },
};

// ── Budgets ──────────────────────────────────────────────────────────────────

export const budgets = {
  list: () => request<{ budgets: AgentBudget[] }>("/budgets"),
  update: (agentName: string, dailyCents: number, monthlyCents: number) =>
    request<{ status: string }>(`/budgets/${encodeURIComponent(agentName)}`, {
      method: "PUT",
      body: JSON.stringify({
        budget_daily_cents: dailyCents,
        budget_monthly_cents: monthlyCents,
      }),
    }),
  reset: (agentName: string) =>
    request<{ status: string }>(
      `/budgets/${encodeURIComponent(agentName)}/reset`,
      { method: "POST" },
    ),
};
