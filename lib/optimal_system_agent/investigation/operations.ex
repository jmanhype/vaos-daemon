defmodule OptimalSystemAgent.Investigation.Operations do
  @moduledoc """
  Concrete parameter mutation operations for investigation MCTS.

  Replaces the abstract operations (decompose, analyze, etc.) with
  8 operations that mutate investigation scoring parameters. All operations
  enforce bounds via clamping and preserve constraints (e.g. citation_weight +
  publisher_weight = 1.0).
  """

  alias OptimalSystemAgent.Investigation.Strategy

  @operations [
    :tighten_grounding,
    :loosen_grounding,
    :shift_hierarchy,
    :widen_search,
    :narrow_search,
    :adjust_direction_sensitivity,
    :rebalance_source_quality,
    :perturb_temperature
  ]

  @doc "List of all available mutation operations."
  @spec operations() :: [atom()]
  def operations, do: @operations

  @doc "Apply a mutation operation to a strategy, returning a new strategy with clamped values."
  @spec apply_op(Strategy.t(), atom()) :: Strategy.t()

  def apply_op(%Strategy{} = s, :tighten_grounding) do
    %{s | grounded_threshold: clamp(s.grounded_threshold + 0.05, 0.2, 0.7)}
  end

  def apply_op(%Strategy{} = s, :loosen_grounding) do
    %{s | grounded_threshold: clamp(s.grounded_threshold - 0.05, 0.2, 0.7)}
  end

  def apply_op(%Strategy{} = s, :shift_hierarchy) do
    delta = :rand.uniform() * 0.4 - 0.2

    %{s |
      review_weight: clamp(s.review_weight + delta, 1.5, 5.0),
      trial_weight: clamp(s.trial_weight + delta * 0.7, 1.0, 3.5),
      study_weight: clamp(s.study_weight + delta * 0.5, 1.0, 2.5)
    }
  end

  def apply_op(%Strategy{} = s, :widen_search) do
    %{s |
      top_n_papers: clamp(s.top_n_papers + 2, 8, 25),
      per_query_limit: clamp(s.per_query_limit + 1, 3, 10)
    }
  end

  def apply_op(%Strategy{} = s, :narrow_search) do
    %{s |
      top_n_papers: clamp(s.top_n_papers - 2, 8, 25),
      per_query_limit: clamp(s.per_query_limit - 1, 3, 10)
    }
  end

  def apply_op(%Strategy{} = s, :adjust_direction_sensitivity) do
    delta = :rand.uniform() * 0.2 - 0.1

    %{s |
      direction_ratio: clamp(s.direction_ratio + delta, 1.1, 2.0),
      belief_fallback_ratio: clamp(s.belief_fallback_ratio + delta * 1.5, 1.2, 2.5)
    }
  end

  def apply_op(%Strategy{} = s, :rebalance_source_quality) do
    shift = :rand.uniform() * 0.1 - 0.05
    new_citation = clamp(s.citation_weight + shift, 0.2, 0.8)
    new_publisher = clamp(1.0 - new_citation, 0.2, 0.8)
    %{s | citation_weight: new_citation, publisher_weight: new_publisher}
  end

  def apply_op(%Strategy{} = s, :perturb_temperature) do
    delta = if :rand.uniform() > 0.5, do: 0.05, else: -0.05
    %{s | adversarial_temperature: clamp(s.adversarial_temperature + delta, 0.0, 0.5)}
  end

  @doc "Clamp a value between min and max bounds."
  @spec clamp(number(), number(), number()) :: number()
  def clamp(value, min_val, max_val) do
    value |> max(min_val) |> min(max_val)
  end
end
