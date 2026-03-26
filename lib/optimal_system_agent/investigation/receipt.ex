defmodule OptimalSystemAgent.Investigation.Receipt do
  @moduledoc """
  Optimization receipt for investigation MCTS runs.

  Records before/after EIG comparison, strategy diff (only changed parameters),
  and MCTS metadata. Does NOT store the full MCTS tree.
  """

  alias OptimalSystemAgent.Investigation.Strategy

  defstruct [
    baseline_eig: 0.0,
    winning_eig: 0.0,
    improvement_pct: 0.0,
    strategy_diff: [],
    iterations_run: 0,
    elapsed_ms: 0,
    tree_size: 0,
    best_path: [],
    parent_hash: nil,
    winning_hash: nil,
    timestamp: ""
  ]

  @type t :: %__MODULE__{}

  @doc "Build a receipt from optimization results."
  @spec build(keyword()) :: t()
  def build(opts) do
    baseline = opts[:baseline_strategy] || Strategy.default()
    winning = opts[:winning_strategy] || Strategy.default()
    baseline_eig = opts[:baseline_eig] || 0.0
    winning_eig = opts[:winning_eig] || 0.0

    diff = strategy_diff(baseline, winning)

    improvement =
      if baseline_eig > 0,
        do: (winning_eig - baseline_eig) / baseline_eig * 100,
        else: 0.0

    %__MODULE__{
      baseline_eig: Float.round(baseline_eig * 1.0, 4),
      winning_eig: Float.round(winning_eig * 1.0, 4),
      improvement_pct: Float.round(improvement * 1.0, 2),
      strategy_diff: diff,
      iterations_run: opts[:iterations_run] || 0,
      elapsed_ms: opts[:elapsed_ms] || 0,
      tree_size: opts[:tree_size] || 0,
      best_path: opts[:best_path] || [],
      parent_hash: Strategy.param_hash(baseline),
      winning_hash: Strategy.param_hash(winning),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc "Compute the diff between two strategies (only changed parameters)."
  @spec strategy_diff(Strategy.t(), Strategy.t()) :: [map()]
  def strategy_diff(%Strategy{} = baseline, %Strategy{} = winning) do
    Strategy.param_keys()
    |> Enum.flat_map(fn key ->
      old_val = Map.get(baseline, key)
      new_val = Map.get(winning, key)

      if old_val != new_val do
        delta =
          if is_number(old_val) and is_number(new_val),
            do: Float.round((new_val - old_val) * 1.0, 4),
            else: nil

        [%{param: key, old: old_val, new: new_val, delta: delta}]
      else
        []
      end
    end)
  end

  @doc "Convert receipt to a JSON-serializable map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = receipt) do
    %{
      baseline_eig: receipt.baseline_eig,
      winning_eig: receipt.winning_eig,
      improvement_pct: receipt.improvement_pct,
      strategy_diff:
        Enum.map(receipt.strategy_diff, fn d ->
          %{
            param: to_string(d.param),
            old: d.old,
            new: d.new,
            delta: d.delta
          }
        end),
      iterations_run: receipt.iterations_run,
      elapsed_ms: receipt.elapsed_ms,
      tree_size: receipt.tree_size,
      best_path: Enum.map(receipt.best_path, &to_string/1),
      parent_hash: receipt.parent_hash,
      winning_hash: receipt.winning_hash,
      timestamp: receipt.timestamp
    }
  end
end
