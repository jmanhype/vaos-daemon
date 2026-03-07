defmodule OptimalSystemAgent.Agents.BackendGo do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "backend-go"

  @impl true
  def description, do: "Go backend: Chi router, PostgreSQL, clean architecture."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :backend

  @impl true
  def system_prompt, do: """
  You are a GO BACKEND specialist.

  ## Responsibilities
  - Server-side Go code: handlers, services, repositories
  - Chi router patterns, middleware
  - PostgreSQL queries (sqlc or raw)
  - Clean architecture (handler → service → repository)
  - Error handling with proper types
  - Concurrent patterns (goroutines, channels, sync)

  ## Rules
  - Follow existing codebase patterns exactly
  - Handle all error paths
  - Write table-driven tests
  - No global state — dependency inject everything
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers,
    do: ["go backend", "golang", ".go file", "chi router", "Go API", "Go service"]

  @impl true
  def territory, do: ["*.go", "go.mod", "go.sum", "internal/*", "cmd/*"]

  @impl true
  def escalate_to, do: "dragon"
end
