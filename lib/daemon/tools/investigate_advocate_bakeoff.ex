defmodule Daemon.Tools.InvestigateAdvocateBakeoff do
  @moduledoc """
  Run a bounded advocate-lane bakeoff on the exact investigate prompts.

  This keeps provider selection empirical when the advocate boundary is the
  first unresolved bottleneck.
  """

  alias Daemon.Investigation.AdversarialParser
  alias Daemon.Tools.Builtins.Investigate
  alias MiosaProviders.Registry, as: Providers

  @provider_priority [
    :openai,
    :google,
    :anthropic,
    :groq,
    :deepseek,
    :qwen,
    :moonshot,
    :zhipu,
    :ollama
  ]

  @default_topic "assess whether caffeine supplementation improves aerobic endurance performance in trained cyclists"
  @stress_probe_timeout_ms 7_500

  def default_topic, do: @default_topic

  def run_topic(topic, opts \\ []) when is_binary(topic) do
    depth = Keyword.get(opts, :depth, "standard")
    steering = Keyword.get(opts, :steering, "")
    timeout_budget = resolve_timeout_budget(opts)

    max_lanes = Keyword.get(opts, :max_lanes, 3)
    explicit_lanes = normalize_explicit_lanes(opts)

    with {:ok, context} <- Investigate.prepare_advocate_bakeoff(topic, depth, steering) do
      lanes =
        case explicit_lanes do
          [] -> candidate_lanes(max_lanes)
          explicit -> Enum.map(explicit, &parse_lane!/1)
        end

      results =
        lanes
        |> Enum.map(&run_lane(topic, context, &1, timeout_budget.timeout_ms))
        |> Enum.map(&summarize_lane_result/1)

      %{
        topic: topic,
        depth: depth,
        timeout_ms: timeout_budget.timeout_ms,
        timeout_mode: timeout_budget.timeout_mode,
        paper_count: length(Map.get(context, :all_papers, [])),
        source_counts: Map.get(context, :source_counts, %{}),
        evidence_plan_mode: get_in(context, [:search_plan, :evidence_plan, :mode]),
        lanes: results,
        winner: pick_winner(results)
      }
    end
  end

  @doc false
  def normalize_explicit_lanes(opts) when is_list(opts) do
    opts
    |> Keyword.get_values(:lane)
    |> Enum.flat_map(fn
      lane when is_binary(lane) -> [lane]
      lanes when is_list(lanes) -> Enum.filter(lanes, &is_binary/1)
      _ -> []
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc false
  def resolve_timeout_budget(opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :timeout_ms) ->
        %{timeout_ms: Keyword.fetch!(opts, :timeout_ms), timeout_mode: "custom"}

      Keyword.get(opts, :stress, false) ->
        %{timeout_ms: @stress_probe_timeout_ms, timeout_mode: "stress_probe"}

      true ->
        %{
          timeout_ms: Investigate.advocate_timeout_ms(),
          timeout_mode: "production_default"
        }
    end
  end

  @doc false
  def candidate_lanes(limit \\ 3) when is_integer(limit) and limit > 0 do
    current_provider = Investigate.preferred_advocate_provider()

    current_lane =
      lane_spec(current_provider, Investigate.preferred_advocate_model(current_provider))

    configured_providers =
      [current_provider | @provider_priority]
      |> Enum.uniq()
      |> Enum.filter(&Providers.provider_configured?/1)

    configured_providers
    |> Enum.map(fn provider ->
      model =
        if provider == current_provider do
          Investigate.preferred_advocate_model(provider)
        else
          Investigate.preferred_utility_model(provider)
        end

      lane_spec(provider, model)
    end)
    |> Kernel.++([current_lane])
    |> Enum.uniq_by(&lane_identity/1)
    |> Enum.take(limit)
  end

  @doc false
  def summarize_lane_result(result) when is_map(result) do
    for_side = Map.get(result, :for, %{})
    against_side = Map.get(result, :against, %{})

    success_sides = Enum.count([for_side, against_side], &(Map.get(&1, :status) == "ok"))
    parsed_items = Map.get(for_side, :parsed_items, 0) + Map.get(against_side, :parsed_items, 0)

    sourced_items =
      Map.get(for_side, :sourced_items, 0) + Map.get(against_side, :sourced_items, 0)

    structured_sides =
      Enum.count([for_side, against_side], fn side ->
        Map.get(side, :parsed_items, 0) in 3..5
      end)

    total_latency_ms = Map.get(for_side, :elapsed_ms, 0) + Map.get(against_side, :elapsed_ms, 0)
    viable = success_sides > 0 and parsed_items > 0 and sourced_items > 0

    Map.merge(result, %{
      success_sides: success_sides,
      parsed_items: parsed_items,
      sourced_items: sourced_items,
      structured_sides: structured_sides,
      total_latency_ms: total_latency_ms,
      viable: viable,
      selection_score:
        success_sides * 100 + sourced_items * 10 + parsed_items * 3 + structured_sides * 5 -
          div(total_latency_ms, 1_000)
    })
  end

  @doc false
  def pick_winner(results) when is_list(results) do
    results
    |> Enum.filter(&lane_viable?/1)
    |> Enum.max_by(
      fn result ->
        {
          Map.get(result, :success_sides, 0),
          Map.get(result, :sourced_items, 0),
          Map.get(result, :parsed_items, 0),
          Map.get(result, :structured_sides, 0),
          -Map.get(result, :total_latency_ms, 0)
        }
      end,
      fn -> nil end
    )
  end

  defp run_lane(topic, context, lane, timeout_ms) do
    opts =
      context
      |> Map.get(:llm_opts, [])
      |> Keyword.put(:provider, lane.provider)
      |> Keyword.put(:receive_timeout, timeout_ms)
      |> Keyword.put(:allow_fallback, false)
      |> then(fn opts ->
        if lane.model,
          do: Keyword.put(opts, :model, lane.model),
          else: Keyword.delete(opts, :model)
      end)

    {for_result, for_elapsed_ms} =
      Investigate.run_advocate_chat_phase(topic, :for_bakeoff, context.for_messages, opts)

    {against_result, against_elapsed_ms} =
      Investigate.run_advocate_chat_phase(topic, :against_bakeoff, context.against_messages, opts)

    %{
      lane: lane,
      for: side_summary(for_result, for_elapsed_ms),
      against: side_summary(against_result, against_elapsed_ms)
    }
  end

  defp side_summary({:ok, %{content: content}}, elapsed_ms)
       when is_binary(content) and content != "" do
    parsed = AdversarialParser.parse(content)

    %{
      status: "ok",
      elapsed_ms: elapsed_ms,
      parsed_items: length(parsed),
      sourced_items:
        Enum.count(parsed, &(&1.source_type == :sourced and is_integer(&1.paper_ref))),
      reasoning_items: Enum.count(parsed, &(&1.source_type == :reasoning)),
      preview: content |> String.replace(~r/\s+/, " ") |> String.slice(0, 240)
    }
  end

  defp side_summary({:ok, %{content: ""}}, elapsed_ms) do
    %{
      status: "empty",
      elapsed_ms: elapsed_ms,
      parsed_items: 0,
      sourced_items: 0,
      reasoning_items: 0
    }
  end

  defp side_summary({:error, reason}, elapsed_ms) do
    %{
      status: "error",
      elapsed_ms: elapsed_ms,
      parsed_items: 0,
      sourced_items: 0,
      reasoning_items: 0,
      error: inspect(reason)
    }
  end

  defp side_summary(other, elapsed_ms) do
    %{
      status: "other",
      elapsed_ms: elapsed_ms,
      parsed_items: 0,
      sourced_items: 0,
      reasoning_items: 0,
      error: inspect(other)
    }
  end

  defp parse_lane!(spec) when is_binary(spec) do
    provider_name =
      spec
      |> String.split(":", parts: 2)
      |> List.first()
      |> to_string()
      |> String.trim()

    provider =
      Enum.find(Providers.list_providers(), fn candidate ->
        to_string(candidate) == provider_name
      end) || raise ArgumentError, "unknown provider lane: #{spec}"

    model =
      case String.split(spec, ":", parts: 2) do
        [_provider] ->
          Investigate.preferred_utility_model(provider)

        [_provider, explicit_model] ->
          explicit_model
          |> String.trim()
          |> case do
            "" -> Investigate.preferred_utility_model(provider)
            value -> value
          end
      end

    lane_spec(provider, model)
  end

  defp lane_spec(provider, model) when is_atom(provider) do
    %{
      provider: provider,
      model: model,
      label: "#{provider}:#{model || "default"}"
    }
  end

  defp lane_identity(%{provider: provider, model: model}), do: {provider, model}

  defp lane_viable?(result) when is_map(result), do: Map.get(result, :viable, false)
end
