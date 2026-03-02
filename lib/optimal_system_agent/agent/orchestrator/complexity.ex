defmodule OptimalSystemAgent.Agent.Orchestrator.Complexity do
  @moduledoc """
  LLM-based complexity analysis for task decomposition.

  Determines whether a task is simple (single agent) or complex (multi-agent)
  by asking the LLM to analyze it. For complex tasks, returns a list of sub-tasks
  with roles, dependencies, and required tools.
  """
  require Logger

  alias OptimalSystemAgent.Agent.{Roster, Orchestrator.SubTask}
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @doc """
  Analyze a task message for complexity.

  Returns `:simple` or `{:complex, [SubTask.t()]}`.
  """
  @spec analyze(String.t()) :: :simple | {:complex, [SubTask.t()]}
  def analyze(message) do
    prompt = """
    Analyze this task's complexity. Respond ONLY with valid JSON, no markdown fences.

    Task: "#{String.slice(message, 0, 500)}"

    Determine:
    1. complexity: "simple" (one agent can handle) or "complex" (needs multiple parallel agents)
    2. If complex, decompose into parallel sub-tasks (max #{Roster.max_agents()})
    3. For each sub-task, specify:
       - name: short identifier (snake_case)
       - description: what this agent should do
       - role: one of the 9 specialist roles below
       - tools_needed: which skills this agent needs (file_read, file_write, shell_execute, web_search, memory_save)
       - depends_on: list of other sub-task names it depends on (empty array for parallel tasks)

    Available roles (assign the most appropriate for each sub-task):
      "lead"     — orchestrator/synthesizer, merges results, makes ship decisions
      "backend"  — server-side code: APIs, handlers, services, business logic
      "frontend" — client-side code: components, pages, state, styling
      "data"     — database schemas, migrations, models, queries, data integrity
      "design"   — design specs, tokens, accessibility audits, visual consistency
      "infra"    — Dockerfiles, CI/CD, deployment, build systems, monitoring
      "qa"       — tests (unit/integration/e2e), test infra, security audit
      "red_team" — adversarial review: security vulns, edge cases, findings report
      "services" — external integrations: APIs, workers, background jobs, AI/ML

    Execution waves (sub-tasks are grouped into dependency waves):
      Wave 1 (foundation): data, qa, infra, design — no dependencies
      Wave 2 (logic):      backend, services — depends on Wave 1
      Wave 3 (presentation): frontend — depends on Wave 2
      Wave 4 (review):     red_team — depends on all prior waves
      Wave 5 (synthesis):  lead — depends on everything

    JSON format:
    {"complexity":"simple","reasoning":"This is a straightforward task"}
    OR
    {"complexity":"complex","reasoning":"This task requires...","sub_tasks":[{"name":"schema_design","description":"...","role":"data","tools_needed":["file_read"],"depends_on":[]},{"name":"api_handlers","description":"...","role":"backend","tools_needed":["file_read","file_write"],"depends_on":["schema_design"]}]}
    """

    messages = [%{role: "user", content: prompt}]

    case Providers.chat(messages, temperature: 0.2, max_tokens: 1500) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        parse_response(content)

      {:ok, _} ->
        Logger.warning("[Orchestrator] Empty LLM response for complexity analysis")
        :simple

      {:error, reason} ->
        Logger.error(
          "[Orchestrator] LLM call failed during complexity analysis: #{inspect(reason)}"
        )

        :simple
    end
  end

  @doc "Parse a raw LLM response into complexity result."
  @spec parse_response(String.t()) :: :simple | {:complex, [SubTask.t()]}
  def parse_response(content) do
    cleaned =
      content
      |> String.trim()
      |> OptimalSystemAgent.Utils.Text.strip_markdown_fences()
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"complexity" => "simple"}} ->
        :simple

      {:ok, %{"complexity" => "complex", "sub_tasks" => sub_tasks}} when is_list(sub_tasks) ->
        parsed =
          Enum.map(sub_tasks, fn st ->
            %SubTask{
              name: st["name"] || "unnamed",
              description: st["description"] || "",
              role: parse_role(st["role"]),
              tools_needed: st["tools_needed"] || [],
              depends_on: st["depends_on"] || []
            }
          end)

        {:complex, parsed}

      {:ok, _} ->
        Logger.warning("[Orchestrator] Unexpected complexity response format")
        :simple

      {:error, reason} ->
        Logger.warning("[Orchestrator] Failed to parse complexity JSON: #{inspect(reason)}")
        :simple
    end
  end

  # Agent-Dispatch 9-role system + legacy aliases
  @doc false
  def parse_role("lead"), do: :lead
  def parse_role("backend"), do: :backend
  def parse_role("frontend"), do: :frontend
  def parse_role("data"), do: :data
  def parse_role("design"), do: :design
  def parse_role("infra"), do: :infra
  def parse_role("qa"), do: :qa
  def parse_role("red_team"), do: :red_team
  def parse_role("red-team"), do: :red_team
  def parse_role("services"), do: :services
  # Legacy aliases
  def parse_role("researcher"), do: :data
  def parse_role("builder"), do: :backend
  def parse_role("tester"), do: :qa
  def parse_role("reviewer"), do: :red_team
  def parse_role("writer"), do: :lead
  def parse_role(_), do: :backend
end
