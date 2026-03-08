defmodule OptimalSystemAgent.Agent.Strategies.Reflection do
  @moduledoc """
  Reflection reasoning strategy.

  Iteratively improves a response through self-critique and revision:
  Generate -> Critique -> Revise -> Repeat until quality threshold or max rounds.

  Best for: debugging, code review, refactoring tasks.
  """

  @behaviour OptimalSystemAgent.Agent.Strategy

  @default_max_rounds 3

  @no_issues_patterns [
    ~r/no issues found/i,
    ~r/no significant (issues|problems|flaws)/i,
    ~r/response is (excellent|perfect|complete|thorough)/i,
    ~r/nothing (to|that needs to be) (improve|fix|change|address)/i
  ]

  # ── Behaviour Callbacks ──────────────────────────────────────────

  @impl true
  def name, do: :reflection

  @impl true
  def select?(%{task_type: type}) when type in [:debugging, :review, :refactor], do: true
  def select?(%{complexity: c}) when is_integer(c) and c in 8..9, do: true
  def select?(_), do: false

  @impl true
  def init_state(context) do
    %{
      phase: :generate,
      task: Map.get(context, :task, ""),
      max_rounds: Map.get(context, :max_rounds, @default_max_rounds),
      round: 0,
      content: nil,
      critiques: [],
      current_critique: nil
    }
  end

  @impl true
  def next_step(%{phase: :generate} = state, _context) do
    prompt = "Provide a thorough response to this task:\n\n#{state.task}"
    step = {:think, prompt}
    new_state = %{state | phase: :critique}
    {step, new_state}
  end

  def next_step(%{phase: :critique, round: r, max_rounds: max} = state, _context)
      when r >= max do
    result = %{
      rounds: state.round,
      critiques: state.critiques
    }

    {{:done, result}, state}
  end

  def next_step(%{phase: :critique} = state, _context) do
    prompt =
      "Critically evaluate this response to the given task.\n" <>
        "Identify specific flaws, missing information, logical errors, or areas for improvement.\n" <>
        "If the response is already excellent, state \"NO ISSUES FOUND\".\n\n" <>
        "Original task: #{state.task}\n\n" <>
        "Response to evaluate:\n#{state.content}"

    step = {:think, prompt}
    new_state = %{state | phase: :check_critique}
    {step, new_state}
  end

  def next_step(%{phase: :check_critique} = state, _context) do
    if substantive_critique?(state.current_critique) do
      prompt =
        "Revise this response based on the critique. Address every issue raised.\n" <>
          "Maintain what was already good. Produce a complete, improved response.\n\n" <>
          "Original task: #{state.task}\n\n" <>
          "Current response:\n#{state.content}\n\n" <>
          "Critique:\n#{state.current_critique}"

      step = {:think, prompt}
      new_state = %{state | phase: :revise}
      {step, new_state}
    else
      # Critique found no substantive issues — we're done
      result = %{
        rounds: state.round,
        critiques: state.critiques ++ [state.current_critique]
      }

      {{:done, result}, state}
    end
  end

  def next_step(%{phase: :revise} = state, _context) do
    # After revision, loop back to critique
    new_state = %{
      state
      | phase: :critique,
        round: state.round + 1,
        critiques: state.critiques ++ [state.current_critique],
        current_critique: nil
    }

    # Re-enter critique phase
    next_step(new_state, %{})
  end

  @impl true
  def handle_result({:think, _}, response, %{phase: :critique} = state)
      when is_binary(response) do
    %{state | content: response}
  end

  def handle_result({:think, _}, response, %{phase: :check_critique} = state)
      when is_binary(response) do
    %{state | current_critique: response}
  end

  def handle_result({:think, _}, response, %{phase: :revise} = state)
      when is_binary(response) do
    %{state | content: response}
  end

  def handle_result(_step, _result, state), do: state

  # ── Public Helpers ───────────────────────────────────────────────

  @doc "Returns true if the critique text contains substantive issues to address."
  @spec substantive_critique?(String.t() | nil) :: boolean()
  def substantive_critique?(nil), do: false

  def substantive_critique?(text) when is_binary(text) do
    not Enum.any?(@no_issues_patterns, &Regex.match?(&1, text))
  end
end
