defmodule OptimalSystemAgent.Agent.Orchestrator.GoalDispatch do
  @moduledoc """
  Goal-oriented dispatch for orchestrator agents.

  Instead of sending step-by-step instructions to each agent, this module
  builds goal packets: WHAT to achieve + relevant context. The agent's own
  system prompt and expertise handle the HOW.

  This is Pattern #4 from research synthesis:
  "Pass: goal + context. Let agent's system prompt handle HOW."

  ## Usage

      goal = GoalDispatch.build_goal(:backend, "Add pagination to /api/users", %{
        files: ["lib/api/users.ex"],
        constraints: ["must be backward-compatible"],
        prior_results: %{"explorer" => "Found 3 list endpoints without pagination"}
      })

      prompt = GoalDispatch.dispatch(goal, agent_config)
      # => A formatted prompt with GOAL + CONTEXT + TOOLS, no step-by-step instructions

      results = GoalDispatch.merge_results([
        %{agent: "backend", status: :ok, output: "Added cursor pagination..."},
        %{agent: "test", status: :ok, output: "Wrote 12 tests..."}
      ])
      # => Unified synthesis of all agent outputs
  """

  # ── Types ──────────────────────────────────────────────────────────

  @type role :: atom()

  @type context_map :: %{
          optional(:files) => [String.t()],
          optional(:constraints) => [String.t()],
          optional(:prior_results) => %{optional(String.t()) => String.t()},
          optional(:tools) => [String.t()],
          optional(:dependencies) => [String.t()],
          optional(:metadata) => map()
        }

  @type goal :: %{
          role: role(),
          objective: String.t(),
          context: context_map(),
          built_at: DateTime.t()
        }

  @type goal_result :: %{
          agent: String.t(),
          status: :ok | :error,
          output: String.t(),
          metadata: map()
        }

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Build a goal struct for an agent.

  Takes a role, a plain-language task description (the WHAT), and a context
  map with relevant files, constraints, prior wave results, etc.

  Returns a goal map ready for `dispatch/2`.
  """
  @spec build_goal(role(), String.t(), context_map()) :: goal()
  def build_goal(role, task_description, context \\ %{}) when is_atom(role) and is_binary(task_description) do
    %{
      role: role,
      objective: String.trim(task_description),
      context: normalize_context(context),
      built_at: DateTime.utc_now()
    }
  end

  @doc """
  Format a goal into a dispatch prompt for the agent.

  Takes a goal (from `build_goal/3`) and an agent config map (from Roster or
  custom). Produces a prompt that communicates:

  - The GOAL (what to achieve)
  - The CONTEXT (files, prior results, constraints)
  - The TOOLS available
  - NO step-by-step instructions — the agent decides HOW

  The agent_config map supports:
  - `:name` — agent name (for logging/identity)
  - `:tier` — :elite | :specialist | :utility
  - `:prompt` — base system prompt (optional, looked up from Roster if absent)
  """
  @spec dispatch(goal(), map()) :: String.t()
  def dispatch(goal, agent_config \\ %{}) do
    sections = [
      build_goal_section(goal),
      build_context_section(goal.context),
      build_tools_section(goal.context),
      build_constraints_section(goal.context),
      build_execution_frame(agent_config)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Merge results from multiple goal-dispatched agents into a unified output.

  Separates successes from failures, synthesizes the successful outputs into
  a coherent summary, and surfaces any errors clearly.
  """
  @spec merge_results([goal_result()]) :: %{
          status: :ok | :partial | :error,
          synthesis: String.t(),
          succeeded: [goal_result()],
          failed: [goal_result()]
        }
  def merge_results([]) do
    %{
      status: :error,
      synthesis: "No agent results to merge.",
      succeeded: [],
      failed: []
    }
  end

  def merge_results(results) when is_list(results) do
    results = Enum.map(results, &normalize_result/1)

    {succeeded, failed} = Enum.split_with(results, &(&1.status == :ok))

    status =
      cond do
        failed == [] -> :ok
        succeeded == [] -> :error
        true -> :partial
      end

    synthesis = build_synthesis(succeeded, failed)

    %{
      status: status,
      synthesis: synthesis,
      succeeded: succeeded,
      failed: failed
    }
  end

  # ── Private: Goal section ──────────────────────────────────────────

  defp build_goal_section(goal) do
    role_label = goal.role |> to_string() |> String.replace("_", " ") |> String.capitalize()

    """
    ## Goal
    **Role**: #{role_label}
    **Objective**: #{goal.objective}

    Achieve this objective using your expertise and available tools. \
    You decide the approach — focus on the outcome, not prescribed steps.\
    """
  end

  # ── Private: Context section ───────────────────────────────────────

  defp build_context_section(%{files: files, prior_results: prior} = _ctx)
       when (is_list(files) and files != []) or (is_map(prior) and map_size(prior) > 0) do
    parts = []

    parts =
      if is_list(files) and files != [] do
        file_list = Enum.map_join(files, "\n", &("- `#{&1}`"))
        parts ++ ["### Relevant Files\n#{file_list}"]
      else
        parts
      end

    parts =
      if is_map(prior) and map_size(prior) > 0 do
        prior_block =
          prior
          |> Enum.map_join("\n\n", fn {agent, output} ->
            "**#{agent}**:\n#{output}"
          end)

        parts ++ ["### Prior Agent Results\n#{prior_block}"]
      else
        parts
      end

    if parts == [] do
      nil
    else
      "## Context\n" <> Enum.join(parts, "\n\n")
    end
  end

  defp build_context_section(_), do: nil

  # ── Private: Tools section ─────────────────────────────────────────

  defp build_tools_section(%{tools: tools}) when is_list(tools) and tools != [] do
    tool_list = Enum.join(tools, ", ")
    "## Available Tools\n#{tool_list}"
  end

  defp build_tools_section(_), do: nil

  # ── Private: Constraints section ───────────────────────────────────

  defp build_constraints_section(%{constraints: constraints})
       when is_list(constraints) and constraints != [] do
    constraint_list = Enum.map_join(constraints, "\n", &("- #{&1}"))
    "## Constraints\n#{constraint_list}"
  end

  defp build_constraints_section(_), do: nil

  # ── Private: Execution frame ───────────────────────────────────────

  defp build_execution_frame(agent_config) when map_size(agent_config) == 0, do: nil

  defp build_execution_frame(agent_config) do
    parts = []

    parts =
      case Map.get(agent_config, :name) do
        nil -> parts
        name -> parts ++ ["- Agent: #{name}"]
      end

    parts =
      case Map.get(agent_config, :tier) do
        nil -> parts
        tier -> parts ++ ["- Tier: #{tier}"]
      end

    if parts == [] do
      nil
    else
      "## Execution\n" <> Enum.join(parts, "\n")
    end
  end

  # ── Private: Context normalization ─────────────────────────────────

  defp normalize_context(ctx) when is_map(ctx) do
    %{
      files: Map.get(ctx, :files, []),
      constraints: Map.get(ctx, :constraints, []),
      prior_results: Map.get(ctx, :prior_results, %{}),
      tools: Map.get(ctx, :tools, []),
      dependencies: Map.get(ctx, :dependencies, []),
      metadata: Map.get(ctx, :metadata, %{})
    }
  end

  # ── Private: Result normalization ──────────────────────────────────

  defp normalize_result(%{agent: _, status: _, output: _} = result) do
    Map.put_new(result, :metadata, %{})
  end

  defp normalize_result(result) when is_map(result) do
    %{
      agent: Map.get(result, :agent, "unknown"),
      status: Map.get(result, :status, :error),
      output: Map.get(result, :output, ""),
      metadata: Map.get(result, :metadata, %{})
    }
  end

  # ── Private: Synthesis ─────────────────────────────────────────────

  defp build_synthesis(succeeded, failed) do
    parts = []

    parts =
      if succeeded != [] do
        success_block =
          succeeded
          |> Enum.map_join("\n\n", fn r ->
            "### #{r.agent}\n#{r.output}"
          end)

        parts ++ ["## Completed\n#{success_block}"]
      else
        parts
      end

    parts =
      if failed != [] do
        failure_block =
          failed
          |> Enum.map_join("\n\n", fn r ->
            "### #{r.agent} (FAILED)\n#{r.output}"
          end)

        parts ++ ["## Failed\n#{failure_block}"]
      else
        parts
      end

    case parts do
      [] -> "No results."
      _ -> Enum.join(parts, "\n\n")
    end
  end
end
