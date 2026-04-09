defmodule Daemon.Tools.InvestigateOverlapProfiler do
  @moduledoc """
  Runs traced investigate calls and summarizes cross-side verification overlap.

  This keeps the analysis workflow reproducible when verifier scheduling
  decisions need fresh data from real investigate runs.
  """

  alias Daemon.Tools.Builtins.Investigate

  @default_topics [
    "does moderate alcohol consumption improve long-term health outcomes in adults",
    "is long-term artificial sweetener consumption safe for adults",
    "does creatine supplementation improve cognitive performance in healthy adults"
  ]

  @vaos_json_regex ~r/<!-- VAOS_JSON:(?<json>.*) -->/s

  def default_topics, do: @default_topics

  def run_topics(topics, opts \\ []) when is_list(topics) do
    trace_label = Keyword.get(opts, :trace_label, "overlap-profile")
    depth = Keyword.get(opts, :depth, "standard")

    snapshots =
      topics
      |> Enum.map(&String.trim(to_string(&1)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.with_index(1)
      |> Enum.map(fn {topic, index} -> run_topic(topic, index, trace_label, depth) end)

    %{
      topics: snapshots,
      summary: summarize(snapshots)
    }
  end

  def extract_metadata(output) when is_binary(output) do
    case String.trim(output) do
      "Investigation skipped" <> _ = reason ->
        {:skip, reason}

      trimmed_output ->
        with %{"json" => json} <- Regex.named_captures(@vaos_json_regex, trimmed_output),
             {:ok, metadata} <- Jason.decode(json) do
          {:ok, metadata}
        else
          nil ->
            {:error, "VAOS_JSON payload not found"}

          {:error, reason} ->
            {:error, "failed to decode VAOS_JSON payload: #{inspect(reason)}"}
        end
    end
  end

  def overlap_snapshot(metadata) when is_map(metadata) do
    stats = map_value(metadata, :verification_stats) || %{}

    %{
      status: "ok",
      topic: map_value(metadata, :topic),
      investigation_id: map_value(metadata, :investigation_id),
      direction: map_value(metadata, :direction),
      trace_label: map_value(metadata, :trace_label),
      trace_path: map_value(metadata, :trace_path),
      total_items: integer_value(stats, :total_items),
      llm_items: integer_value(stats, :llm_items),
      cross_side_overlap_items: integer_value(stats, :cross_side_overlap_items),
      cross_side_unique_llm_items: integer_value(stats, :cross_side_unique_llm_items),
      cross_side_overlap_rate: float_value(stats, :cross_side_overlap_rate),
      supporting_overlap_rate: float_value(stats, :supporting_overlap_rate),
      opposing_overlap_rate: float_value(stats, :opposing_overlap_rate),
      cross_side_overlap_examples:
        stats
        |> map_value(:cross_side_overlap_examples)
        |> normalize_examples()
    }
  end

  def summarize(snapshots) when is_list(snapshots) do
    successful = Enum.filter(snapshots, &(&1[:status] == "ok"))
    run_count = length(successful)

    total_overlap_items =
      successful
      |> Enum.map(&Map.get(&1, :cross_side_overlap_items, 0))
      |> Enum.sum()

    total_unique_items =
      successful
      |> Enum.map(&Map.get(&1, :cross_side_unique_llm_items, 0))
      |> Enum.sum()

    zero_overlap_runs =
      Enum.count(successful, fn snapshot ->
        Map.get(snapshot, :cross_side_overlap_items, 0) == 0
      end)

    %{
      run_count: run_count,
      zero_overlap_runs: zero_overlap_runs,
      zero_overlap_rate: ratio(zero_overlap_runs, run_count),
      total_cross_overlap_items: total_overlap_items,
      total_cross_side_unique_llm_items: total_unique_items,
      aggregate_cross_side_overlap_rate: ratio(total_overlap_items, total_unique_items),
      average_cross_side_overlap_rate: average_rate(successful, :cross_side_overlap_rate),
      average_supporting_overlap_rate: average_rate(successful, :supporting_overlap_rate),
      average_opposing_overlap_rate: average_rate(successful, :opposing_overlap_rate),
      topics_with_overlap:
        successful
        |> Enum.filter(&(Map.get(&1, :cross_side_overlap_items, 0) > 0))
        |> Enum.map(&Map.get(&1, :topic))
        |> Enum.reject(&is_nil/1),
      top_overlap_examples: aggregate_examples(successful),
      failures:
        snapshots
        |> Enum.filter(&(&1[:status] != "ok"))
        |> Enum.map(&Map.take(&1, [:topic, :status, :error]))
    }
  end

  defp run_topic(topic, index, trace_label, depth) do
    label = "#{trace_label}-#{index}"

    args = %{
      "topic" => topic,
      "depth" => depth,
      "metadata" => %{
        "trace_capture" => true,
        "trace_label" => label
      }
    }

    case Investigate.execute(args) do
      {:ok, output} ->
        case extract_metadata(output) do
          {:ok, metadata} ->
            overlap_snapshot(metadata)

          {:skip, reason} ->
            %{
              status: "skipped",
              topic: topic,
              error: reason
            }

          {:error, reason} ->
            %{
              status: "metadata_parse_error",
              topic: topic,
              error: reason
            }
        end

      {:error, reason} ->
        %{
          status: "investigate_error",
          topic: topic,
          error: inspect(reason)
        }
    end
  rescue
    error ->
      %{
        status: "crash",
        topic: topic,
        error: Exception.message(error)
      }
  end

  defp map_value(payload, key) when is_map(payload) and is_atom(key) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp integer_value(payload, key) do
    case map_value(payload, key) do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        round(value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _} -> parsed
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp float_value(payload, key) do
    case map_value(payload, key) do
      value when is_float(value) ->
        Float.round(value, 3)

      value when is_integer(value) ->
        value / 1

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, _} -> Float.round(parsed, 3)
          :error -> 0.0
        end

      _ ->
        0.0
    end
  end

  defp normalize_examples(nil), do: []

  defp normalize_examples(examples) when is_list(examples) do
    Enum.map(examples, fn example ->
      %{
        paper_ref: integer_value(example, :paper_ref),
        claim: map_value(example, :claim),
        summary: map_value(example, :summary)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()
    end)
  end

  defp normalize_examples(_), do: []

  defp average_rate([], _key), do: 0.0

  defp average_rate(snapshots, key) do
    snapshots
    |> Enum.map(&Map.get(&1, key, 0.0))
    |> Enum.sum()
    |> Kernel./(length(snapshots))
    |> Float.round(3)
  end

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: Float.round(numerator / denominator, 3)

  defp aggregate_examples(snapshots) do
    snapshots
    |> Enum.flat_map(&Map.get(&1, :cross_side_overlap_examples, []))
    |> Enum.reduce(%{}, fn example, acc ->
      key = {Map.get(example, :paper_ref), Map.get(example, :claim)}

      Map.update(
        acc,
        key,
        %{
          paper_ref: Map.get(example, :paper_ref),
          claim: Map.get(example, :claim),
          summary: Map.get(example, :summary),
          count_runs: 1
        },
        fn existing -> Map.update!(existing, :count_runs, &(&1 + 1)) end
      )
    end)
    |> Map.values()
    |> Enum.sort_by(fn example ->
      {
        -Map.get(example, :count_runs, 0),
        Map.get(example, :paper_ref, 0),
        Map.get(example, :claim, "")
      }
    end)
    |> Enum.take(10)
  end
end
