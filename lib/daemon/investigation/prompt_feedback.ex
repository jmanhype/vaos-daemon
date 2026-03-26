defmodule Daemon.Investigation.PromptFeedback do
  @moduledoc """
  Records verification outcomes per prompt version for the GEPA feedback loop.

  Each investigation run records: which prompt hash was used, the topic,
  and the citation verification metrics. GEPA reads these to weight its
  metric with real production outcomes instead of self-grading.

  Storage: ~/.daemon/prompt_feedback/{prompt_hash}_{topic_hash}.json
  """

  require Logger

  @store_dir Path.join(System.user_home!(), ".daemon/prompt_feedback")

  @doc "Record the outcome of an investigation's citation verification."
  @spec record(String.t(), String.t(), map()) :: :ok
  def record(prompt_hash, topic, %{} = metrics) do
    File.mkdir_p!(@store_dir)

    entry = %{
      "prompt_hash" => prompt_hash,
      "topic" => topic,
      "metrics" => normalize_metrics(metrics),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    path = entry_path(prompt_hash, topic)
    existing = load_entries(path)
    File.write!(path, Jason.encode!(existing ++ [entry], pretty: true))
    Logger.debug("[prompt_feedback] Recorded feedback for #{prompt_hash} on #{String.slice(topic, 0, 50)}")
    :ok
  end

  @doc "Load all feedback entries (for GEPA metric weighting)."
  @spec load_all() :: [map()]
  def load_all do
    if File.dir?(@store_dir) do
      @store_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.flat_map(fn file ->
        load_entries(Path.join(@store_dir, file))
      end)
    else
      []
    end
  end

  @doc "Aggregate verification rate for a prompt hash."
  @spec aggregate(String.t()) :: %{avg_verification_rate: float(), sample_count: integer()}
  def aggregate(prompt_hash) do
    entries =
      load_all()
      |> Enum.filter(fn e -> e["prompt_hash"] == prompt_hash end)

    if entries == [] do
      %{avg_verification_rate: 0.0, sample_count: 0}
    else
      rates = Enum.map(entries, fn e ->
        get_in(e, ["metrics", "verification_rate"]) || 0.0
      end)

      %{
        avg_verification_rate: Enum.sum(rates) / length(rates),
        sample_count: length(entries)
      }
    end
  end

  @doc "Return the store directory path (for testing)."
  @spec store_dir() :: String.t()
  def store_dir, do: @store_dir

  # -- Private --

  defp entry_path(prompt_hash, topic) do
    topic_h = :crypto.hash(:sha256, topic) |> Base.encode16(case: :lower) |> String.slice(0, 12)
    Path.join(@store_dir, "#{prompt_hash}_#{topic_h}.json")
  end

  defp load_entries(path) do
    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  defp normalize_metrics(metrics) do
    %{
      "total_sourced" => metrics[:total_sourced] || metrics["total_sourced"] || 0,
      "verified" => metrics[:verified] || metrics["verified"] || 0,
      "partial" => metrics[:partial] || metrics["partial"] || 0,
      "unverified" => metrics[:unverified] || metrics["unverified"] || 0,
      "verification_rate" => metrics[:verification_rate] || metrics["verification_rate"] || 0.0
    }
  end
end
