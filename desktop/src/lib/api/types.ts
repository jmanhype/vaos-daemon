// src/lib/api/types.ts
// All TypeScript types for the OSA API (localhost:9089/api/v1)

// ── Health ────────────────────────────────────────────────────────────────────

export interface HealthResponse {
  status: "ok" | "degraded" | "error";
  version: string;
  uptime_seconds: number;
  provider: string | null;
  agents_active: number;
}

// ── Onboarding ────────────────────────────────────────────────────────────────

export interface OnboardingStatus {
  completed: boolean;
  step: "provider" | "model" | "done";
  provider_connected: boolean;
  model_selected: boolean;
}

// ── Sessions ──────────────────────────────────────────────────────────────────

export interface Session {
  id: string;
  title: string | null;
  message_count: number;
  created_at: string | null;
  /** Whether the session's agent loop is still running */
  alive: boolean;
}

export interface CreateSessionRequest {
  title?: string;
  model?: string;
}

export interface CreateSessionResponse {
  /** Backend returns { id, status } on session creation */
  id: string;
  status: string;
}

// ── Messages ──────────────────────────────────────────────────────────────────

export type MessageRole = "user" | "assistant" | "system" | "tool";

export interface ToolCallRef {
  id: string;
  name: string;
  input: Record<string, unknown>;
}

export interface ThinkingBlock {
  type: "thinking";
  thinking: string;
}

export interface Message {
  id: string;
  role: MessageRole;
  content: string;
  timestamp: string;
  tool_calls?: ToolCallRef[];
  /** Extended thinking / reasoning trace, if present */
  thinking?: ThinkingBlock;
}

export interface SendMessageRequest {
  session_id: string;
  content: string;
  model?: string;
  stream?: boolean;
}

export interface SendMessageResponse {
  /** Stream ID to subscribe to via SSE */
  stream_id: string;
  session_id: string;
}

// ── SSE Streaming Events ──────────────────────────────────────────────────────

export type StreamEventType =
  | "streaming_token"
  | "thinking_delta"
  | "tool_call"
  | "tool_result"
  | "system_event"
  | "done"
  | "error";

export interface StreamingTokenEvent {
  type: "streaming_token";
  delta: string;
}

export interface ThinkingDeltaEvent {
  type: "thinking_delta";
  delta: string;
}

export interface ToolCallEvent {
  type: "tool_call";
  tool_use_id: string;
  tool_name: string;
  input: Record<string, unknown>;
  /** Present when the agent is pausing for user permission before executing */
  phase?: "awaiting_permission";
  /** Human-readable description of what the tool will do */
  description?: string;
  /** Relevant file paths or arguments for the permission dialog */
  paths?: string[];
}

export interface ToolResultEvent {
  type: "tool_result";
  tool_use_id: string;
  result: string;
  is_error: boolean;
}

export interface SystemEvent {
  type: "system_event";
  event: string;
  payload?: unknown;
}

export interface DoneEvent {
  type: "done";
  session_id: string;
  message_id: string;
}

export interface ErrorEvent {
  type: "error";
  message: string;
  code?: string;
}

export type StreamEvent =
  | StreamingTokenEvent
  | ThinkingDeltaEvent
  | ToolCallEvent
  | ToolResultEvent
  | SystemEvent
  | DoneEvent
  | ErrorEvent;

// ── Agents ────────────────────────────────────────────────────────────────────

export type AgentStatus = "idle" | "running" | "queued" | "done" | "error";

export interface Agent {
  id: string;
  name: string;
  status: AgentStatus;
  /** 0–100 */
  progress: number;
  task?: string;
  /** Elapsed time in seconds */
  duration?: number;
  /** Tokens consumed in this agent run */
  tokens?: number;
  created_at: string;
  updated_at: string;
  error?: string;
}

// ── Models ────────────────────────────────────────────────────────────────────

export type ModelProvider =
  | "ollama"
  | "ollama-cloud"
  | "anthropic"
  | "openai"
  | "groq"
  | "openrouter";

export interface Model {
  name: string;
  provider: ModelProvider;
  /** Human-readable display name */
  size?: string;
  active: boolean;
  context_window: number;
  description?: string;
  requires_api_key: boolean;
  is_local: boolean;
}

// ── Providers ────────────────────────────────────────────────────────────────

export interface Provider {
  slug: ModelProvider;
  name: string;
  connected: boolean;
  api_key_set: boolean;
}

// ── Settings ──────────────────────────────────────────────────────────────────

export interface Settings {
  provider: ModelProvider;
  model: string;
  api_key?: string;
  working_dir: string;
  budget_daily_usd: number;
  budget_monthly_usd: number;
  theme: "dark" | "light" | "system";
  telemetry: boolean;
}

// ── Orchestrate ───────────────────────────────────────────────────────────────

export interface OrchestrateRequest {
  task: string;
  session_id?: string;
  model?: string;
  agents?: string[];
}

export interface OrchestrateResponse {
  job_id: string;
  session_id: string;
  stream_id: string;
}

// ── Skills Marketplace ───────────────────────────────────────────────────────

export type SkillSource = "builtin" | "user" | "evolved";
export type SkillCategory =
  | "core"
  | "automation"
  | "reasoning"
  | "workflow"
  | "security"
  | "agent"
  | "utility";

export interface Skill {
  id: string;
  name: string;
  description: string;
  category: SkillCategory;
  source: SkillSource;
  enabled: boolean;
  triggers: string[];
  path: string;
  priority: number;
}

export interface SkillDetail extends Skill {
  instructions: string;
  metadata: Record<string, unknown>;
}

export interface SkillCategoryCount {
  name: string;
  count: number;
}

export interface SkillSearchResult {
  id: string;
  name: string;
  description: string;
  score: number;
}

// ── Projects ─────────────────────────────────────────────────────────────────

export type ProjectStatus = "active" | "completed" | "archived";
export type GoalStatus = "active" | "in_progress" | "completed" | "blocked";
export type GoalPriority = "low" | "medium" | "high";

export interface Project {
  id: number;
  name: string;
  description: string | null;
  goal: string | null;
  workspace_path: string | null;
  status: ProjectStatus;
  slug: string;
  metadata: Record<string, unknown>;
  inserted_at: string;
  updated_at: string;
  /** Server-computed aggregates — present on list/get responses */
  goal_count?: number;
  task_count?: number;
  completed_goal_count?: number;
}

export interface Goal {
  id: number;
  title: string;
  description: string | null;
  parent_id: number | null;
  project_id: number;
  status: GoalStatus;
  priority: GoalPriority;
  metadata: Record<string, unknown>;
  inserted_at: string;
  updated_at: string;
}

export interface GoalTreeNode extends Goal {
  children: GoalTreeNode[];
  task_count?: number;
}

export interface ProjectTask {
  id: number;
  project_id: number;
  task_id: string;
  goal_id: number | null;
  goal: Goal | null;
  inserted_at: string;
}

export interface CreateProjectPayload {
  name: string;
  description?: string;
  goal?: string;
  workspace_path?: string;
}

export interface CreateGoalPayload {
  title: string;
  description?: string;
  parent_id?: number;
  priority?: GoalPriority;
}

// ── Budget & Cost Tracking ───────────────────────────────────────────────────

export interface CostEvent {
  id: number;
  agent_name: string;
  session_id: string | null;
  task_id: string | null;
  provider: string;
  model: string;
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  cache_write_tokens: number;
  cost_cents: number;
  inserted_at: string;
}

export interface AgentBudget {
  agent_name: string;
  budget_daily_cents: number;
  budget_monthly_cents: number;
  spent_daily_cents: number;
  spent_monthly_cents: number;
  status: "active" | "paused_budget" | "paused_manual";
  last_reset_daily: string | null;
  last_reset_monthly: string | null;
}

export interface CostSummary {
  daily_spent_cents: number;
  monthly_spent_cents: number;
  daily_limit_cents: number;
  monthly_limit_cents: number;
  daily_events: number;
  monthly_events: number;
}

export interface CostByModel {
  model: string;
  cost_cents: number;
  count: number;
  input_tokens: number;
  output_tokens: number;
}

export interface CostByAgent {
  agent_name: string;
  cost_cents: number;
  count: number;
}

// ── API Error ─────────────────────────────────────────────────────────────────

export interface ApiErrorBody {
  error: string;
  code?: string;
  details?: unknown;
}
