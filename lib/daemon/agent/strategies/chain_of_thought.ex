defmodule Daemon.Agent.Strategies.ChainOfThought do
  @moduledoc """
  Chain of Thought reasoning strategy.

  Prompts step-by-step reasoning with optional self-verification.
  Parses numbered steps and extracts a final answer.

  Best for: analysis tasks, research, reasoning-heavy problems.
  """

  @behaviour Daemon.Agent.Strategy

  # ── Behaviour Callbacks ──────────────────────────────────────────

  @impl true
  def name, do: :chain_of_thought

  @impl true
  def select?(%{task_type: type}) when type in [:analysis, :research], do: true
  def select?(%{complexity: c}) when is_integer(c) and c in 4..5, do: true
  def select?(_), do: false

  @impl true
  def init_state(context) do
    %{
      phase: :reason,
      verify: Map.get(context, :verify, false),
      task: Map.get(context, :task, ""),
      steps: [],
      final_answer: nil,
      reasoning: nil,
      verification: nil
    }
  end

  @impl true
  def next_step(%{phase: :reason} = state, _context) do
    prompt =
      "Think through this step-by-step. Number each step.\n" <>
        "After your reasoning steps, provide your final answer on a line starting with \"FINAL ANSWER:\".\n\n" <>
        "Task: #{state.task}"

    step = {:think, prompt}
    new_state = %{state | phase: :parse}
    {step, new_state}
  end

  def next_step(%{phase: :parse} = state, _context) do
    if state.verify and state.verification == nil do
      prompt =
        "Review the following reasoning for correctness and completeness.\n" <>
          "Identify any logical errors, missing steps, or incorrect conclusions.\n" <>
          "If the reasoning is sound, confirm it. If not, explain the issues.\n\n" <>
          "Original task: #{state.task}\n\n" <>
          "Reasoning:\n#{state.reasoning}"

      step = {:think, prompt}
      new_state = %{state | phase: :verify}
      {step, new_state}
    else
      result = %{
        steps: state.steps,
        final_answer: state.final_answer,
        verified: state.verification != nil,
        verification: state.verification
      }

      {{:done, result}, state}
    end
  end

  def next_step(%{phase: :verify} = state, _context) do
    result = %{
      steps: state.steps,
      final_answer: state.final_answer,
      verified: true,
      verification: state.verification
    }

    {{:done, result}, state}
  end

  @impl true
  def handle_result({:think, _}, response, %{phase: :parse} = state) when is_binary(response) do
    steps = parse_steps(response)
    final_answer = extract_final_answer(response)

    %{state | reasoning: response, steps: steps, final_answer: final_answer}
  end

  def handle_result({:think, _}, response, %{phase: :verify} = state) when is_binary(response) do
    %{state | verification: response, phase: :parse}
  end

  def handle_result(_step, _result, state), do: state

  # ── Parsing Helpers ──────────────────────────────────────────────

  @doc false
  @spec parse_steps(String.t()) :: [String.t()]
  def parse_steps(text) do
    ~r/^\s*(\d+)[.)]\s*(.+)/m
    |> Regex.scan(text)
    |> Enum.map(fn [_full, _num, step] -> String.trim(step) end)
  end

  @doc false
  @spec extract_final_answer(String.t()) :: String.t() | nil
  def extract_final_answer(text) do
    case Regex.run(~r/FINAL ANSWER:\s*(.+)/s, text) do
      [_, answer] -> String.trim(answer)
      _ -> nil
    end
  end
end
