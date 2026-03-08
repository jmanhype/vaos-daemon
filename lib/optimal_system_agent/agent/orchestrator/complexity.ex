defmodule OptimalSystemAgent.Agent.Orchestrator.Complexity do
  @moduledoc """
  LLM-based complexity analysis for task decomposition.

  Determines whether a task is simple (single agent) or complex (multi-agent)
  by asking the LLM to analyze it. For complex tasks, returns a list of sub-tasks
  with roles, dependencies, and required tools.
  """
  require Logger

  alias OptimalSystemAgent.Agent.{Roster, Orchestrator.SubTask}
  alias MiosaProviders.Registry, as: Providers

  @doc """
  Fast heuristic check — no LLM call.

  Returns `:likely_simple` or `:possibly_complex`.
  Use this to decide whether to run the full `analyze/1` call.
  """
  @spec quick_check(String.t()) :: :likely_simple | :possibly_complex
  def quick_check(message) do
    # Long messages with multiple sentences/requests are usually complex.
    len = String.length(message)

    multi_task_patterns = [
      ~r/\band\s+also\b/i,
      ~r/\bthen\s+(also\s+)?(please\s+)?/i,
      ~r/\badditionally\b/i,
      ~r/\bmultiple\b/i,
      ~r/\bcomprehensive\b/i,
      ~r/\bfull\s+(feature|refactor|implementation|migration|overhaul)\b/i,
      ~r/\brefactor\s+and\b/i,
      ~r/\bmigrate\s+and\b/i,
      ~r/^\s*\d+\.\s+.+\n\s*\d+\.\s+/ms,
      ~r/^(\s*[-*]\s+.+\n){3,}/ms
    ]

    has_multi_task = Enum.any?(multi_task_patterns, &Regex.match?(&1, message))
    long_enough = len > 400

    if (has_multi_task and long_enough) or (len > 800) do
      :possibly_complex
    else
      :likely_simple
    end
  end

  @doc """
  Fast heuristic score — no LLM call. Returns an integer 1-10.

  Uses word count, keyword density, and structural signals to estimate
  complexity without burning an LLM call. Suitable for gating decisions
  like whether to ask clarifying questions.
  """
  @spec quick_score(String.t()) :: integer()
  def quick_score(message) do
    lower = String.downcase(message)
    words = String.split(message)
    word_count = length(words)

    # Base score from length
    length_score = cond do
      word_count > 200 -> 4
      word_count > 100 -> 3
      word_count > 50  -> 2
      true             -> 1
    end

    # Cross-domain keywords
    domain_keywords = ~w(frontend backend database api deploy test migrate refactor integrate infrastructure)
    domain_hits = Enum.count(domain_keywords, &String.contains?(lower, &1))
    domain_score = min(domain_hits, 4)

    # Multi-step markers
    step_patterns = [~r/\d+\.\s+/, ~r/\bfirst\b/, ~r/\bthen\b/, ~r/\bfinally\b/, ~r/\bafter\b/]
    step_hits = Enum.count(step_patterns, &Regex.match?(&1, lower))
    step_score = min(step_hits, 3)

    # Complexity indicators
    complex_words = ~w(comprehensive full overhaul migration rewrite architecture)
    complex_hits = Enum.count(complex_words, &String.contains?(lower, &1))
    complex_score = min(complex_hits * 2, 4)

    total = length_score + domain_score + step_score + complex_score
    min(max(total, 1), 10)
  end

  @doc """
  Analyze a task message for complexity.

  Returns `{:simple, score}` or `{:complex, score, [SubTask.t()]}`.
  Score is 1-10 (1=trivial, 10=massive cross-system refactor).

  Options:
    - `:max_agents` — override the maximum sub-task count (default: `Roster.max_agents()`)
  """
  @spec analyze(String.t(), keyword()) :: {:simple, integer()} | {:complex, integer(), [SubTask.t()]}
  def analyze(message, opts \\ []) do
    max_agents = Keyword.get(opts, :max_agents, Roster.max_agents())

    prompt = """
    Analyze this task's complexity. Respond ONLY with valid JSON, no markdown fences.

    Task: "#{String.slice(message, 0, 500)}"

    Determine:
    1. complexity: "simple" (one agent can handle) or "complex" (needs multiple parallel agents)
    2. complexity_score: integer 1-10 (1=trivial single-step, 5=moderate multi-file, 10=massive cross-system refactor)
    3. If complex, decompose into parallel sub-tasks (max #{max_agents})
    4. For each sub-task, specify:
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
    {"complexity":"simple","complexity_score":2,"reasoning":"This is a straightforward task"}
    OR
    {"complexity":"complex","complexity_score":7,"reasoning":"This task requires...","sub_tasks":[{"name":"schema_design","description":"...","role":"data","tools_needed":["file_read"],"depends_on":[]},{"name":"api_handlers","description":"...","role":"backend","tools_needed":["file_read","file_write"],"depends_on":["schema_design"]}]}
    """

    messages = [%{role: "user", content: prompt}]

    case Providers.chat(messages, temperature: 0.2, max_tokens: 1500) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        parse_response(content)

      {:ok, _} ->
        Logger.warning("[Orchestrator] Empty LLM response for complexity analysis")
        {:simple, 3}

      {:error, reason} ->
        Logger.error(
          "[Orchestrator] LLM call failed during complexity analysis: #{inspect(reason)}"
        )

        {:simple, 3}
    end
  end

  @doc "Parse a raw LLM response into complexity result."
  @spec parse_response(String.t()) :: {:simple, integer()} | {:complex, integer(), [SubTask.t()]}
  def parse_response(content) do
    cleaned =
      content
      |> String.trim()
      |> OptimalSystemAgent.Utils.Text.strip_markdown_fences()
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"complexity" => "simple"} = json} ->
        score = parse_complexity_score(json, 3)
        {:simple, score}

      {:ok, %{"complexity" => "complex", "sub_tasks" => sub_tasks} = json} when is_list(sub_tasks) ->
        score = parse_complexity_score(json, 6)

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

        {:complex, score, parsed}

      {:ok, _} ->
        Logger.warning("[Orchestrator] Unexpected complexity response format")
        {:simple, 3}

      {:error, reason} ->
        Logger.warning("[Orchestrator] Failed to parse complexity JSON: #{inspect(reason)}")
        {:simple, 3}
    end
  end

  defp parse_complexity_score(json, default) do
    case json["complexity_score"] do
      n when is_integer(n) and n >= 1 and n <= 10 -> n
      _ -> default
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
