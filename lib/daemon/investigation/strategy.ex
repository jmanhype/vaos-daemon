defmodule Daemon.Investigation.Strategy do
  @moduledoc """
  Investigation parameter vector for MCTS optimization.

  Encapsulates all tunable scoring/classification parameters that were
  previously hardcoded in investigate.ex. Each parameter has defined bounds
  for MCTS mutation operations.
  """

  defstruct [
    # Scoring/classification params (optimized by MCTS)
    grounded_threshold: 0.4,
    citation_weight: 0.5,
    publisher_weight: 0.5,
    review_weight: 3.0,
    trial_weight: 2.0,
    study_weight: 1.5,
    direction_ratio: 1.3,
    belief_fallback_ratio: 1.5,
    top_n_papers: 15,
    per_query_limit: 5,
    adversarial_temperature: 0.1,
    citation_bonus_base: 2.0,
    # Metadata (not optimized)
    topic: "",
    generation: 0,
    parent_hash: nil,
    created_at: ""
  ]

  @param_keys [
    :grounded_threshold,
    :citation_weight,
    :publisher_weight,
    :review_weight,
    :trial_weight,
    :study_weight,
    :direction_ratio,
    :belief_fallback_ratio,
    :top_n_papers,
    :per_query_limit,
    :adversarial_temperature,
    :citation_bonus_base
  ]

  @type t :: %__MODULE__{}

  @doc "List of optimizable parameter keys (excludes metadata)."
  @spec param_keys() :: [atom()]
  def param_keys, do: @param_keys

  @doc "SHA256 hash of parameter values (not metadata) for lineage tracking."
  @spec param_hash(t()) :: String.t()
  def param_hash(%__MODULE__{} = s) do
    values = Enum.map(@param_keys, fn k -> Map.get(s, k) end)

    :crypto.hash(:sha256, :erlang.term_to_binary(values))
    |> Base.encode16(case: :lower)
  end

  @doc "Returns a strategy with current hardcoded defaults."
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc "Parameter bounds for validation and MCTS mutation clamping."
  @spec bounds() :: %{atom() => {number(), number()}}
  def bounds do
    %{
      grounded_threshold: {0.2, 0.7},
      citation_weight: {0.2, 0.8},
      publisher_weight: {0.2, 0.8},
      review_weight: {1.5, 5.0},
      trial_weight: {1.0, 3.5},
      study_weight: {1.0, 2.5},
      direction_ratio: {1.1, 2.0},
      belief_fallback_ratio: {1.2, 2.5},
      top_n_papers: {8, 25},
      per_query_limit: {3, 10},
      adversarial_temperature: {0.0, 0.5},
      citation_bonus_base: {1.5, 10.0}
    }
  end
end
