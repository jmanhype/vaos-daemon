defmodule Daemon.Agent.Strategies.ReAct do
  @moduledoc """
  ReAct (Reason + Act) reasoning strategy.

  The default agent loop strategy. Iterates through Think -> Act -> Observe
  cycles until the task is complete or max iterations are reached.

  Best for: simple tasks, tool-heavy workflows, action-oriented goals.
  """

  @behaviour Daemon.Agent.Strategy

  @default_max_iterations 30

  # ── Behaviour Callbacks ──────────────────────────────────────────

  @impl true
  def name, do: :react

  @impl true
  def select?(%{task_type: type}) when type in [:simple, :action], do: true
  def select?(%{tools: tools}) when is_list(tools) and length(tools) > 0, do: true
  def select?(%{complexity: c}) when is_integer(c) and c <= 3, do: true
  def select?(_), do: false

  @impl true
  def init_state(context) do
    %{
      iteration: 0,
      max_iterations: Map.get(context, :max_iterations, @default_max_iterations),
      phase: :think,
      thoughts: [],
      actions: [],
      observations: []
    }
  end

  @impl true
  def next_step(%{iteration: i, max_iterations: max} = state, _context) when i >= max do
    summary = "Reached max iterations (#{max}). Summarizing findings."
    {{:done, %{reason: :max_iterations, summary: summary}}, state}
  end

  def next_step(%{phase: :think} = state, context) do
    task = Map.get(context, :task, "")
    history = format_history(state)

    thought =
      if state.iteration == 0 do
        "Analyzing task: #{task}"
      else
        "Iteration #{state.iteration + 1}: reviewing observations and planning next action"
      end

    step = {:think, thought <> "\n" <> history}
    new_state = %{state | phase: :act, thoughts: state.thoughts ++ [thought]}
    {step, new_state}
  end

  def next_step(%{phase: :act} = state, _context) do
    step = {:act, :pending, %{iteration: state.iteration}}
    new_state = %{state | phase: :observe}
    {step, new_state}
  end

  def next_step(%{phase: :observe} = state, _context) do
    step = {:observe, "Awaiting tool result for iteration #{state.iteration + 1}"}
    new_state = %{state | phase: :think, iteration: state.iteration + 1}
    {step, new_state}
  end

  @impl true
  def handle_result({:act, _, _}, result, state) do
    %{state | actions: state.actions ++ [result]}
  end

  def handle_result({:observe, _}, result, state) do
    %{state | observations: state.observations ++ [result]}
  end

  def handle_result(_step, _result, state), do: state

  # ── Private ──────────────────────────────────────────────────────

  defp format_history(%{thoughts: [], actions: [], observations: []}), do: ""

  defp format_history(state) do
    entries =
      Enum.zip_with(
        [state.thoughts, state.actions, state.observations],
        fn
          [t, a, o] -> "Thought: #{t}\nAction: #{inspect(a)}\nObservation: #{inspect(o)}"
          _ -> ""
        end
      )

    Enum.join(entries, "\n---\n")
  end
end
