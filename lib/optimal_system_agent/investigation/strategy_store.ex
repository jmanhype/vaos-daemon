defmodule OptimalSystemAgent.Investigation.StrategyStore do
  @moduledoc """
  JSON persistence for investigation strategies.

  Stores winning strategies per topic in ~/.daemon/investigate_strategies/,
  keyed by SHA256 of the topic string. Enables cross-session strategy reuse.
  """

  alias OptimalSystemAgent.Investigation.Strategy

  @store_dir Path.join(System.user_home!(), ".daemon/investigate_strategies")

  @doc "Load the best strategy for a topic. Returns `{:ok, strategy}` or `:error`."
  @spec load_best(String.t()) :: {:ok, Strategy.t()} | :error
  def load_best(topic) when is_binary(topic) do
    path = topic_path(topic)

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, data} -> {:ok, from_map(data)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc "Save a winning strategy to disk."
  @spec save(Strategy.t()) :: :ok
  def save(%Strategy{} = strategy) do
    File.mkdir_p!(@store_dir)
    path = topic_path(strategy.topic)
    json = Jason.encode!(to_map(strategy), pretty: true)
    File.write!(path, json)
    :ok
  end

  @doc "Load all persisted strategies (for future cross-topic learning)."
  @spec load_all() :: [Strategy.t()]
  def load_all do
    if File.dir?(@store_dir) do
      @store_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.flat_map(fn file ->
        path = Path.join(@store_dir, file)

        case File.read(path) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, data} -> [from_map(data)]
              _ -> []
            end

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  @doc "Return the store directory path."
  @spec store_dir() :: String.t()
  def store_dir, do: @store_dir

  defp topic_path(topic) do
    hash =
      :crypto.hash(:sha256, topic)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    Path.join(@store_dir, "#{hash}.json")
  end

  defp to_map(%Strategy{} = s) do
    s
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp from_map(data) when is_map(data) do
    %Strategy{
      grounded_threshold: data["grounded_threshold"] || 0.4,
      citation_weight: data["citation_weight"] || 0.5,
      publisher_weight: data["publisher_weight"] || 0.5,
      review_weight: data["review_weight"] || 3.0,
      trial_weight: data["trial_weight"] || 2.0,
      study_weight: data["study_weight"] || 1.5,
      direction_ratio: data["direction_ratio"] || 1.3,
      belief_fallback_ratio: data["belief_fallback_ratio"] || 1.5,
      top_n_papers: data["top_n_papers"] || 15,
      per_query_limit: data["per_query_limit"] || 5,
      adversarial_temperature: data["adversarial_temperature"] || 0.1,
      citation_bonus_base: data["citation_bonus_base"] || 2.0,
      topic: data["topic"] || "",
      generation: data["generation"] || 0,
      parent_hash: data["parent_hash"],
      created_at: data["created_at"] || ""
    }
  end
end
