defmodule OptimalSystemAgent.Agent.Orchestrator.Decomposer do
  @moduledoc """
  Task decomposition and wave planning for the Orchestrator.

  Responsible for:
  - Analyzing task complexity via the LLM
  - Decomposing complex tasks into ordered sub-tasks
  - Grouping sub-tasks into dependency-aware execution waves
  - Building context strings from completed dependency results
  """
  require Logger

  alias OptimalSystemAgent.Agent.Orchestrator.{Complexity, SubTask}

  @doc """
  Decompose a task message into a list of SubTask structs.

  Returns `{:ok, [SubTask.t()]}` or `{:error, reason}`.
  For simple tasks, returns a single "execute" sub-task.
  For complex tasks, returns the LLM-generated decomposition.
  """
  @spec decompose_task(String.t()) :: {:ok, [SubTask.t()]} | {:error, term()}
  def decompose_task(message) do
    try do
      case Complexity.analyze(message) do
        :simple ->
          {:ok,
           [
             %SubTask{
               name: "execute",
               description: message,
               role: :builder,
               tools_needed: ["file_read", "file_write", "shell_execute"],
               depends_on: []
             }
           ]}

        {:complex, sub_tasks} ->
          {:ok, sub_tasks}
      end
    rescue
      e ->
        {:error, "Task decomposition failed: #{Exception.message(e)}"}
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
