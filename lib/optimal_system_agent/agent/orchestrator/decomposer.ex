defmodule OptimalSystemAgent.Agent.Orchestrator.Decomposer do
  @moduledoc """
  Task decomposition and wave planning for the Orchestrator.

  Responsible for:
  - Analyzing task complexity via the LLM
  - Decomposing complex tasks into ordered sub-tasks
  - Grouping sub-tasks into dependency-aware execution waves
  - Building context strings from completed dependency results
  - Cost estimation to avoid unnecessary multi-agent overhead
  - Skill discovery to prefer existing skills over decomposition
  """
  require Logger

  alias OptimalSystemAgent.Agent.Orchestrator.{Complexity, Explorer, SubTask}
  alias OptimalSystemAgent.Tools.Registry, as: ToolRegistry

  # Multi-agent overhead in estimated tokens (prompt scaffolding, coordination, etc.)
  @multi_agent_overhead 800
  # Ratio threshold: if multi-agent cost exceeds single-agent by this factor, keep single
  @cost_ratio_threshold 1.5

  @doc """
  Decompose a task message into a list of SubTask structs.

  Returns `{:ok, [SubTask.t()]}` or `{:error, reason}`.

  Before calling the LLM for decomposition:
  1. Checks if an existing skill covers the task (avoids decomposition entirely).
  2. Estimates whether multi-agent decomposition is cost-justified.

  For simple tasks, returns an explore sub-task followed by execute.
  For complex tasks, returns the LLM-generated decomposition with an
  Explorer as Wave 0 so all agents have codebase context before acting.
  """
  @spec decompose_task(String.t(), keyword()) :: {:ok, [SubTask.t()], map()} | {:error, term()}
  def decompose_task(message, opts \\ []) do
    try do
      # 1. Check if a matching skill exists — prefer skill execution over decomposition
      case find_relevant_skill(message) do
        {:ok, skill} ->
          Logger.info("[Decomposer] Matched skill '#{skill.name}' — using skill execution instead of decomposition")
          sub_tasks = [build_skill_subtask(message, skill)]
          {:ok, sub_tasks, %{estimated_tokens: estimate_tokens(message, sub_tasks), complexity_score: 2}}

        :no_match ->
          # 2. Heuristic: skip LLM decomposition call for tasks that clearly don't need it
          if should_decompose?(message) do
            case Complexity.analyze(message, opts) do
              {:simple, score} ->
                sub_tasks = [
                  %SubTask{
                    name: "execute",
                    description: message,
                    role: :backend,
                    tools_needed: ["file_read", "file_write", "shell_execute"],
                    depends_on: []
                  }
                ]
                {:ok, sub_tasks, %{estimated_tokens: estimate_tokens(message, sub_tasks), complexity_score: score}}

              {:complex, score, sub_tasks} ->
                # 3. Estimate cost before committing to multi-agent execution
                if cost_justified?(message, sub_tasks) do
                  final_tasks = Explorer.inject_explore_phase(sub_tasks, message)
                  {:ok, final_tasks, %{estimated_tokens: estimate_tokens(message, final_tasks), complexity_score: score}}
                else
                  Logger.info(
                    "[Decomposer] Multi-agent cost not justified (#{length(sub_tasks)} sub-tasks) — keeping as single agent"
                  )

                  single = [
                    %SubTask{
                      name: "execute",
                      description: message,
                      role: :backend,
                      tools_needed: ["file_read", "file_write", "shell_execute"],
                      depends_on: []
                    }
                  ]
                  {:ok, single, %{estimated_tokens: estimate_tokens(message, single), complexity_score: score}}
                end
            end
          else
            Logger.debug("[Decomposer] Task below decomposition threshold — skipping LLM analysis")

            sub_tasks = [
              %SubTask{
                name: "execute",
                description: message,
                role: :backend,
                tools_needed: ["file_read", "file_write", "shell_execute"],
                depends_on: []
              }
            ]
            {:ok, sub_tasks, %{estimated_tokens: estimate_tokens(message, sub_tasks), complexity_score: 2}}
          end
      end
    rescue
      e ->
        {:error, "Task decomposition failed: #{Exception.message(e)}"}
    end
  end

  @doc """
  Heuristic gate: returns true only if a task is worth sending to the LLM decomposer.

  Skips decomposition when the task has fewer than 30 words OR a complexity score
  below 0.6 (determined by a simple structural analysis of the description).
  This prevents wasting an LLM call on straightforward one-liner tasks.
  """
  @spec should_decompose?(String.t()) :: boolean()
  def should_decompose?(task_description) do
    word_count = task_description |> String.split() |> length()
    complexity_score = estimate_complexity_score(task_description)
    complexity_score > 0.6 and word_count > 30
  end

  @doc """
  Estimate a simple 0.0–1.0 complexity score from structural signals in the task text.

  Signals that increase score:
  - Multiple sentences / clauses (and, then, also, next, after)
  - Technical keywords implying cross-domain work (deploy, test, migrate, refactor)
  - Explicit step enumeration (1., 2., first, second, finally)
  """
  @spec estimate_complexity_score(String.t()) :: float()
  def estimate_complexity_score(text) do
    lower = String.downcase(text)

    coordination_words = ~w(and then also next after additionally furthermore moreover plus)
    cross_domain_keywords = ~w(deploy test migrate refactor integrate update database api frontend backend)
    step_markers = ~w(first second third finally step)

    coord_hits = Enum.count(coordination_words, &String.contains?(lower, &1))
    domain_hits = Enum.count(cross_domain_keywords, &String.contains?(lower, &1))
    step_hits = Enum.count(step_markers, &String.contains?(lower, &1))

    raw = coord_hits * 0.1 + domain_hits * 0.15 + step_hits * 0.2
    min(raw, 1.0)
  end

  @doc """
  Estimate whether multi-agent decomposition is cost-justified compared to a single agent.

  Uses a simple token heuristic:
  - Single-agent: word_count * 1.5 tokens_in + 600 tokens_out
  - Multi-agent: overhead + sum over sub-tasks of (sub_task_word_count * 1.5 + 400)

  Returns false (keep single agent) when multi-agent cost exceeds single-agent by
  more than `@cost_ratio_threshold` (1.5×). Also returns false for fewer than 3 sub-tasks
  unless they are clearly cross-domain (different roles).
  """
  @spec cost_justified?(String.t(), [SubTask.t()]) :: boolean()
  def cost_justified?(task_description, sub_tasks) do
    # Short-circuit: fewer than 3 distinct sub-tasks rarely need multi-agent
    distinct_roles = sub_tasks |> Enum.map(& &1.role) |> Enum.uniq() |> length()

    if length(sub_tasks) < 3 and distinct_roles < 2 do
      false
    else
      word_count = task_description |> String.split() |> length()
      single_agent_cost = round(word_count * 1.5) + 600

      multi_agent_cost =
        @multi_agent_overhead +
          Enum.reduce(sub_tasks, 0, fn st, acc ->
            sub_words = st.description |> String.split() |> length()
            acc + round(sub_words * 1.5) + 400
          end)

      ratio = multi_agent_cost / max(single_agent_cost, 1)

      Logger.debug(
        "[Decomposer] Cost estimate — single: #{single_agent_cost}, multi: #{multi_agent_cost}, ratio: #{Float.round(ratio, 2)}"
      )

      ratio <= @cost_ratio_threshold
    end
  end

  @doc """
  Search registered skills for one that matches the task description.

  Delegates to `ToolRegistry.search/1` which scores all tools and skills by keyword
  relevance. Returns `{:ok, skill}` if the top match is a skill (not a builtin tool)
  and its score exceeds 0.5, otherwise `:no_match`.
  """
  @spec find_relevant_skill(String.t()) :: {:ok, map()} | :no_match
  def find_relevant_skill(task_description) do
    results = ToolRegistry.search(task_description)
    skills = :persistent_term.get({ToolRegistry, :skills}, %{})

    # Only consider results that are skills (not builtin tools) with score > 0.5
    skill_match =
      results
      |> Enum.find(fn {name, _desc, score} ->
        score > 0.5 and Map.has_key?(skills, name)
      end)

    case skill_match do
      {name, _desc, score} ->
        skill = Map.get(skills, name)
        Logger.debug("[Decomposer] Skill match: '#{name}' (score: #{score})")
        {:ok, skill}

      nil ->
        :no_match
    end
  rescue
    _ -> :no_match
  end

  # Estimate total token cost for the chosen execution path.
  # Single-agent: word_count * 1.5 + 600 output tokens.
  # Multi-agent: coordination overhead + per-sub-task cost.
  defp estimate_tokens(message, sub_tasks) do
    word_count = message |> String.split() |> length()

    if length(sub_tasks) <= 1 do
      round(word_count * 1.5) + 600
    else
      @multi_agent_overhead +
        Enum.reduce(sub_tasks, 0, fn st, acc ->
          sub_words = st.description |> String.split() |> length()
          acc + round(sub_words * 1.5) + 400
        end)
    end
  end

  # Build a single sub-task that uses the matched skill's path as its instructions source.
  defp build_skill_subtask(message, skill) do
    %SubTask{
      name: "skill_execute",
      description: "Execute using skill '#{skill.name}': #{message}",
      role: :backend,
      tools_needed: ["file_read"] ++ (skill[:tools] || []),
      depends_on: []
    }
  end

  @doc """
  Generate clarifying questions for complex tasks.
  Returns a list of question maps for the survey dialog.
  """
  @spec generate_questions(String.t()) :: [map()]
  def generate_questions(message) when is_binary(message) do
    base_questions = [
      %{
        text: "What is the primary goal of this task?",
        multi_select: false,
        options: [
          %{label: "Build new feature", description: "Create something that doesn't exist yet"},
          %{label: "Fix a bug", description: "Resolve an existing issue or error"},
          %{label: "Refactor/improve", description: "Restructure or optimize existing code"},
          %{label: "Research/explore", description: "Investigate or analyze without making changes"}
        ],
        skippable: true
      },
      %{
        text: "What's your quality priority?",
        multi_select: false,
        options: [
          %{label: "Speed", description: "Get it working fast, iterate later"},
          %{label: "Quality", description: "Production-ready with tests and error handling"},
          %{label: "Balanced", description: "Reasonable quality without over-engineering"}
        ],
        skippable: true
      }
    ]

    if cross_domain_task?(message) do
      base_questions ++
        [
          %{
            text: "Which areas should agents focus on?",
            multi_select: true,
            options: detect_domain_options(message),
            skippable: true
          }
        ]
    else
      base_questions
    end
  end

  defp cross_domain_task?(message) do
    domains = ~w(frontend backend database api ui test deploy infra)
    msg = String.downcase(message)
    Enum.count(domains, fn d -> String.contains?(msg, d) end) >= 2
  end

  defp detect_domain_options(message) do
    msg = String.downcase(message)

    all_options = [
      {"Frontend/UI", "frontend", "Components, styling, client-side logic"},
      {"Backend/API", "backend", "Server logic, endpoints, business rules"},
      {"Database", "database", "Schema changes, migrations, queries"},
      {"Testing", "test", "Unit tests, integration tests, E2E"},
      {"Infrastructure", "infra", "Docker, CI/CD, deployment"},
      {"Documentation", "doc", "README, API docs, comments"}
    ]

    matched =
      all_options
      |> Enum.filter(fn {_label, keyword, _desc} -> String.contains?(msg, keyword) end)
      |> Enum.map(fn {label, _kw, desc} -> %{label: label, description: desc} end)

    case matched do
      [] ->
        [
          %{label: "Frontend/UI", description: "Components, styling, client-side logic"},
          %{label: "Backend/API", description: "Server logic, endpoints, business rules"},
          %{label: "Testing", description: "Unit tests, integration tests, E2E"}
        ]

      opts ->
        opts
    end
  end

  @doc """
  Group a flat list of sub-tasks into topologically ordered execution waves.

  Wave 0 contains tasks with no dependencies. Each subsequent wave contains
  tasks whose dependencies are all satisfied by previous waves.

  Returns a list of lists: `[[SubTask.t()]]`.
  """
  @spec build_execution_waves([SubTask.t()]) :: [[SubTask.t()]]
  def build_execution_waves(sub_tasks) do
    resolved = MapSet.new()
    remaining = sub_tasks
    waves = []

    build_waves(remaining, resolved, waves)
  end

  @doc """
  Recursive wave builder. Groups `remaining` tasks into waves based on
  which tasks have all their `depends_on` entries in `resolved`.

  Returns the accumulated `waves` list in forward order when `remaining` is empty.
  """
  @spec build_waves([SubTask.t()], MapSet.t(), [[SubTask.t()]]) :: [[SubTask.t()]]
  def build_waves([], _resolved, waves), do: Enum.reverse(waves)

  def build_waves(remaining, resolved, waves) do
    {ready, not_ready} =
      Enum.split_with(remaining, fn st ->
        Enum.all?(st.depends_on, fn dep -> MapSet.member?(resolved, dep) end)
      end)

    if ready == [] and not_ready != [] do
      # Circular dependency or unresolvable — force everything into one wave
      Logger.warning(
        "[Orchestrator] Unresolvable dependencies detected, forcing parallel execution"
      )

      Enum.reverse([not_ready | waves])
    else
      new_resolved =
        Enum.reduce(ready, resolved, fn st, acc -> MapSet.put(acc, st.name) end)

      build_waves(not_ready, new_resolved, [ready | waves])
    end
  end

  @doc """
  Build a context string from the results of completed dependency tasks.

  Returns `nil` if `depends_on` is empty or no results are available yet.
  Otherwise returns a formatted markdown string with each dependency's output.
  """
  @spec build_dependency_context([String.t()], map()) :: String.t() | nil
  def build_dependency_context([], _results), do: nil

  def build_dependency_context(depends_on, results) do
    context_parts =
      Enum.map(depends_on, fn dep_name ->
        case Map.get(results, dep_name) do
          nil -> nil
          result -> "## Results from #{dep_name}:\n#{result}"
        end
      end)
      |> Enum.reject(&is_nil/1)

    if context_parts == [] do
      nil
    else
      Enum.join(context_parts, "\n\n---\n\n")
    end
  end
end
