defmodule Daemon.Agent.Strategies.TreeOfThoughts do
  @moduledoc """
  Tree of Thoughts reasoning strategy.

  Explores multiple reasoning paths in parallel, evaluates each, and selects
  the best approach. Falls back to next-best on failure.

  Best for: planning, design, architecture decisions.
  """

  @behaviour Daemon.Agent.Strategy

  @default_candidates 3

  # ── Behaviour Callbacks ──────────────────────────────────────────

  @impl true
  def name, do: :tree_of_thoughts

  @impl true
  def select?(%{task_type: type}) when type in [:planning, :design, :architecture], do: true
  def select?(%{complexity: c}) when is_integer(c) and c in 6..7, do: true
  def select?(_), do: false

  @impl true
  def init_state(context) do
    %{
      phase: :generate,
      task: Map.get(context, :task, ""),
      num_candidates: Map.get(context, :candidates, @default_candidates),
      candidates: [],
      ranked: [],
      selected_index: nil,
      backtrack_count: 0
    }
  end

  @impl true
  def next_step(%{phase: :generate} = state, _context) do
    prompt =
      "Generate exactly #{state.num_candidates} different approaches to solve this task.\n" <>
        "For each approach, provide a brief title and a 2-3 sentence description.\n" <>
        "Format each as:\n\n" <>
        "APPROACH 1: [Title]\n[Description]\n\n" <>
        "APPROACH 2: [Title]\n[Description]\n\n" <>
        "... and so on.\n\n" <>
        "Task: #{state.task}"

    step = {:think, prompt}
    new_state = %{state | phase: :evaluate}
    {step, new_state}
  end

  def next_step(%{phase: :evaluate, candidates: []} = state, _context) do
    # No candidates parsed, bail out
    {{:done, %{reason: :no_candidates}}, state}
  end

  def next_step(%{phase: :evaluate} = state, _context) do
    candidates_text =
      state.candidates
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {c, i} -> "APPROACH #{i}: #{c}" end)

    prompt =
      "Evaluate these approaches for the given task. Rate each from 1-10 on:\n" <>
        "- Feasibility, Quality, Efficiency\n\n" <>
        "Rank them best to worst. Format as:\nRANKING: [comma-separated approach numbers, best first]\n\n" <>
        "Task: #{state.task}\n\n#{candidates_text}"

    step = {:think, prompt}
    new_state = %{state | phase: :execute}
    {step, new_state}
  end

  def next_step(%{phase: :execute, ranked: []} = state, _context) do
    {{:done, %{reason: :all_approaches_failed}}, state}
  end

  def next_step(%{phase: :execute, ranked: [approach | _]} = state, _context) do
    prompt =
      "Execute this approach to solve the task. Provide a complete, thorough response.\n\n" <>
        "Approach: #{approach}\n\nTask: #{state.task}"

    step = {:think, prompt}
    new_state = %{state | phase: :done}
    {step, new_state}
  end

  def next_step(%{phase: :done} = state, _context) do
    result = %{
      candidates: state.candidates,
      ranked: state.ranked,
      selected_index: state.selected_index,
      backtrack_count: state.backtrack_count
    }

    {{:done, result}, state}
  end

  @impl true
  def handle_result({:think, _}, response, %{phase: :evaluate} = state)
      when is_binary(response) do
    candidates = parse_approaches(response, state.num_candidates)
    %{state | candidates: candidates}
  end

  def handle_result({:think, _}, response, %{phase: :execute} = state)
      when is_binary(response) do
    ranking = parse_ranking(response, length(state.candidates))

    ranked =
      Enum.map(ranking, fn i -> Enum.at(state.candidates, i) end)
      |> Enum.reject(&is_nil/1)

    ranked = if ranked == [], do: state.candidates, else: ranked
    %{state | ranked: ranked, selected_index: 0}
  end

  def handle_result({:think, _}, _response, %{phase: :done} = state), do: state

  # Tool result list from the agent loop — extract text summaries from each
  # tool outcome and treat them as evaluation input for the current phase.
  def handle_result({:act, :tools, _}, results, state) when is_list(results) do
    tool_summary =
      results
      |> Enum.map(fn
        %{tool: tool, result: r} when is_binary(r) -> "#{tool}: #{r}"
        %{tool: tool, result: r} -> "#{tool}: #{inspect(r)}"
        other -> inspect(other)
      end)
      |> Enum.join("\n")

    case state.phase do
      :evaluate ->
        # Feed tool results as candidate approaches when in evaluation phase
        candidates = if tool_summary != "", do: [tool_summary | state.candidates], else: state.candidates
        %{state | candidates: Enum.take(candidates, state.num_candidates)}

      _ ->
        state
    end
  end

  def handle_result(_step, _result, state), do: state

  # ── Parsing Helpers ──────────────────────────────────────────────

  @doc false
  @spec parse_approaches(String.t(), non_neg_integer()) :: [String.t()]
  def parse_approaches(text, expected_count) do
    results =
      ~r/APPROACH\s*\d+:\s*(.+?)(?=APPROACH\s*\d+:|$)/s
      |> Regex.scan(text)
      |> Enum.map(fn [_full, content] -> String.trim(content) end)

    if results == [] do
      text
      |> String.split(~r/\n\n+/)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.take(expected_count)
    else
      Enum.take(results, expected_count)
    end
  end

  @doc false
  @spec parse_ranking(String.t(), non_neg_integer()) :: [non_neg_integer()]
  def parse_ranking(text, count) do
    case Regex.run(~r/RANKING:\s*(.+)/i, text) do
      [_, ranking_str] ->
        ranking_str
        |> String.split(~r/[,\s]+/)
        |> Enum.map(fn s ->
          case Integer.parse(String.trim(s)) do
            {n, _} -> n - 1
            :error -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&(&1 >= 0 and &1 < count))

      _ ->
        Enum.to_list(0..(count - 1))
    end
  end
end
