defmodule OptimalSystemAgent.Agent.Strategy do
  @moduledoc """
  Behaviour for pluggable reasoning strategies.

  Each strategy defines how the agent loop reasons about a task. The behaviour
  supports both one-shot strategies (CoT, Reflection) and iterative loops
  (ReAct, ToT, MCTS) through a step-based interface.

  ## Callbacks

    * `name/0` — atom identifier for the strategy
    * `select?/1` — returns true if this strategy is a good fit for the context
    * `init_state/1` — initialize strategy-specific state from task context
    * `next_step/2` — given strategy state and context, return the next action
    * `handle_result/3` — process a step result and return updated state

  ## Auto-Resolution

  `resolve/1` picks the best strategy for a given context map by consulting
  each strategy's `select?/1` heuristic, falling back to complexity scoring.
  """

  @type context :: %{
          optional(:task) => String.t(),
          optional(:complexity) => integer(),
          optional(:task_type) => atom(),
          optional(:tools) => list(),
          optional(:history) => list(),
          optional(any()) => any()
        }

  @type strategy_state :: map()

  @type step ::
          {:think, String.t()}
          | {:act, atom(), map()}
          | {:observe, String.t()}
          | {:respond, String.t()}
          | {:done, map()}

  @doc "Atom identifier for this strategy."
  @callback name() :: atom()

  @doc "Returns true if this strategy is a good fit for the given context."
  @callback select?(context()) :: boolean()

  @doc "Initialize strategy-specific state from a task context."
  @callback init_state(context()) :: strategy_state()

  @doc "Determine the next step given current strategy state and context."
  @callback next_step(strategy_state(), context()) :: {step(), strategy_state()}

  @doc "Process the result of a step and return updated strategy state."
  @callback handle_result(step(), term(), strategy_state()) :: strategy_state()

  # ── Strategy Registry ────────────────────────────────────────────

  @strategies [
    OptimalSystemAgent.Agent.Strategies.ReAct,
    OptimalSystemAgent.Agent.Strategies.ChainOfThought,
    OptimalSystemAgent.Agent.Strategies.TreeOfThoughts,
    OptimalSystemAgent.Agent.Strategies.Reflection,
    OptimalSystemAgent.Agent.Strategies.MCTS
  ]

  # ── Public API ───────────────────────────────────────────────────

  @doc """
  Resolve the best strategy for the given context.

  Strategy selection priority:
  1. Explicit `:strategy` key in context (atom name)
  2. Task-type heuristic mapping
  3. Complexity-based fallback

  ## Task Type Mapping

    * `:simple`, `:action` → ReAct
    * `:analysis`, `:research` → ChainOfThought
    * `:planning`, `:design`, `:architecture` → TreeOfThoughts
    * `:debugging`, `:review`, `:refactor` → Reflection
    * `:exploration`, `:optimization`, `:search` → MCTS
  """
  @spec resolve(context()) :: {:ok, module()} | {:error, :unknown_strategy}
  def resolve(%{strategy: name}) when is_atom(name) do
    resolve_by_name(name)
  end

  def resolve(context) do
    # Try each strategy's select?/1 heuristic
    case Enum.find(@strategies, fn mod -> mod.select?(context) end) do
      nil -> {:ok, fallback_strategy(context)}
      mod -> {:ok, mod}
    end
  end

  @doc """
  Resolve a strategy by its atom name.

  ## Examples

      iex> {:ok, mod} = OptimalSystemAgent.Agent.Strategy.resolve_by_name(:react)
      iex> mod.name()
      :react
  """
  @spec resolve_by_name(atom()) :: {:ok, module()} | {:error, :unknown_strategy}
  def resolve_by_name(name) when is_atom(name) do
    case Enum.find(@strategies, fn mod -> mod.name() == name end) do
      nil -> {:error, :unknown_strategy}
      mod -> {:ok, mod}
    end
  end

  @doc "List all registered strategies."
  @spec all() :: [%{name: atom(), module: module()}]
  def all do
    Enum.map(@strategies, fn mod ->
      %{name: mod.name(), module: mod}
    end)
  end

  @doc "List strategy names."
  @spec names() :: [atom()]
  def names, do: Enum.map(@strategies, & &1.name())

  # ── Private ──────────────────────────────────────────────────────

  @task_type_map %{
    simple: :react,
    action: :react,
    analysis: :chain_of_thought,
    research: :chain_of_thought,
    planning: :tree_of_thoughts,
    design: :tree_of_thoughts,
    architecture: :tree_of_thoughts,
    debugging: :reflection,
    review: :reflection,
    refactor: :reflection,
    exploration: :mcts,
    optimization: :mcts,
    search: :mcts
  }

  defp fallback_strategy(%{task_type: task_type}) when is_atom(task_type) do
    case Map.get(@task_type_map, task_type) do
      nil -> default_by_complexity(nil)
      name -> find_strategy!(name)
    end
  end

  defp fallback_strategy(%{complexity: c}) when is_integer(c), do: default_by_complexity(c)
  defp fallback_strategy(_), do: find_strategy!(:react)

  defp default_by_complexity(c) when is_integer(c) and c <= 3, do: find_strategy!(:react)
  defp default_by_complexity(c) when is_integer(c) and c <= 5, do: find_strategy!(:chain_of_thought)
  defp default_by_complexity(c) when is_integer(c) and c <= 7, do: find_strategy!(:tree_of_thoughts)
  defp default_by_complexity(c) when is_integer(c) and c <= 9, do: find_strategy!(:reflection)
  defp default_by_complexity(c) when is_integer(c) and c >= 10, do: find_strategy!(:mcts)
  defp default_by_complexity(_), do: find_strategy!(:react)

  defp find_strategy!(name) do
    Enum.find(@strategies, fn mod -> mod.name() == name end)
  end
end
