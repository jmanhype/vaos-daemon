defmodule Daemon.Telemetry.Metrics do
  @moduledoc """
  Telemetry GenServer for OSA runtime metrics.

  Subscribes to Events.Bus and tracks:
    - :tool_executions    — count by tool name (histogram)
    - :provider_latency   — avg/p99 latency by provider (last 100 calls)
    - :provider_calls     — total call count by provider atom
    - :session_stats      — turns per session, messages per day, sessions today
    - :token_stats        — cumulative input/output tokens from llm_response usage map
    - :noise_filter_rate  — % messages filtered by noise filter
    - :signal_weights     — distribution by bucket (0-0.2, 0.2-0.5, 0.5-0.8, 0.8-1.0)

  Writes a snapshot to ~/.daemon/metrics.json every 5 minutes.

  ## Public API

      Metrics.record_tool_execution("search_files", 42)
      Metrics.record_provider_call(:anthropic, 1200, true)
      Metrics.record_noise_filter_result(:filtered)
      Metrics.record_signal_weight(0.73)
      Metrics.get_metrics()
      Metrics.get_summary()

  ## /analytics-facing summary

      Metrics.get_analytics_summary()
      # => %{
      #      sessions_today: integer,
      #      total_messages: integer,
      #      tokens_used: integer,
      #      top_tools: [{tool_name, call_count}, ...],
      #      provider_calls: %{provider_atom => call_count}
      #    }
  """

  use GenServer
  require Logger

  @flush_interval_ms 5 * 60 * 1_000
  @latency_window 100

  # ── Public API ───────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Record a tool execution with its duration in milliseconds."
  def record_tool_execution(tool_name, duration_ms)
      when is_binary(tool_name) and is_number(duration_ms) do
    GenServer.cast(__MODULE__, {:tool_execution, tool_name, duration_ms})
  end

  @doc "Record an LLM provider call with latency and success flag."
  def record_provider_call(provider, latency_ms, success)
      when is_atom(provider) and is_number(latency_ms) and is_boolean(success) do
    GenServer.cast(__MODULE__, {:provider_call, provider, latency_ms, success})
  end

  @doc "Record the outcome of a noise filter check (:filtered | :clarify | :pass)."
  def record_noise_filter_result(outcome) when outcome in [:filtered, :clarify, :pass] do
    GenServer.cast(__MODULE__, {:noise_filter, outcome})
  end

  @doc "Record a signal weight value (0.0–1.0) for distribution tracking."
  def record_signal_weight(weight) when is_float(weight) or is_integer(weight) do
    GenServer.cast(__MODULE__, {:signal_weight, weight / 1.0})
  end

  @doc "Returns raw metrics map from ETS."
  def get_metrics do
    case :ets.whereis(:daemon_telemetry) do
      :undefined -> %{}
      _ -> build_metrics()
    end
  end

  @doc "Returns a human-readable summary map."
  def get_summary do
    m = get_metrics()

    noise = m[:noise_filter] || %{filtered: 0, clarify: 0, pass: 0}
    total_noise = noise.filtered + noise.clarify + noise.pass
    filter_rate = if total_noise > 0, do: (noise.filtered + noise.clarify) / total_noise, else: 0.0

    %{
      tool_executions: summarize_tool_executions(Map.get(m, :tool_executions, %{})),
      provider_latency: summarize_latencies(Map.get(m, :provider_latency, %{})),
      provider_calls: Map.get(m, :provider_calls, %{}),
      provider_errors: Map.get(m, :provider_errors, %{}),
      session_stats: Map.get(m, :session_stats, %{turns_by_session: %{}, messages_today: 0, sessions_today: 0}),
      token_stats: Map.get(m, :token_stats, %{input_tokens: 0, output_tokens: 0}),
      noise_filter_rate: Float.round(filter_rate * 100, 2),
      signal_weight_distribution: Map.get(m, :signal_weights, empty_weight_buckets())
    }
  end

  @doc """
  Returns the summary map expected by the `/analytics` command and the
  `/api/analytics` HTTP route.

  Fields:
    - `sessions_today`  — distinct session IDs seen since midnight (ETS-based)
    - `total_messages`  — cumulative `:user_message` and `:llm_response` events
    - `tokens_used`     — total input + output tokens from all `llm_response` events
    - `top_tools`       — list of `{tool_name, call_count}` sorted descending by count
    - `provider_calls`  — map of `provider_atom => call_count`
  """
  def get_analytics_summary do
    m = get_metrics()

    session_stats = Map.get(m, :session_stats, %{turns_by_session: %{}, messages_today: 0, sessions_today: 0})
    token_stats = Map.get(m, :token_stats, %{input_tokens: 0, output_tokens: 0})
    tool_executions = Map.get(m, :tool_executions, %{})
    provider_calls = Map.get(m, :provider_calls, %{})

    top_tools =
      tool_executions
      |> Enum.map(fn {name, stats} -> {name, stats.count} end)
      |> Enum.sort_by(fn {_name, count} -> count end, :desc)
      |> Enum.take(10)

    %{
      sessions_today: Map.get(session_stats, :sessions_today, 0),
      total_messages: Map.get(session_stats, :messages_today, 0),
      tokens_used: Map.get(token_stats, :input_tokens, 0) + Map.get(token_stats, :output_tokens, 0),
      top_tools: top_tools,
      provider_calls: provider_calls
    }
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    try do
      :ets.new(:daemon_telemetry, [:named_table, :public, :set])
    rescue
      ArgumentError -> :ok
    end

    seed_table()
    subscribe_to_events()

    schedule_flush()
    Logger.info("[Telemetry.Metrics] Started — flushing to ~/.daemon/metrics.json every 5m")
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    flush_to_disk()
    :ok
  end

  @impl true
  def handle_cast({:tool_execution, tool_name, duration_ms}, state) do
    update_tool_execution(tool_name, duration_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:provider_call, provider, latency_ms, success}, state) do
    update_provider_latency(provider, latency_ms)
    update_provider_call_count(provider)
    unless success, do: update_provider_error_count(provider)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:noise_filter, outcome}, state) do
    update_noise_filter(outcome)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:signal_weight, weight}, state) do
    update_signal_weight(weight)
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    flush_to_disk()
    schedule_flush()
    {:noreply, state}
  end

  # Handle events forwarded from Events.Bus subscriptions
  def handle_info({:daemon_event, payload}, state) do
    handle_event(payload)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Event Bus Subscriptions ──────────────────────────────────────────

  defp subscribe_to_events do
    self_pid = self()

    # tool_result events emit `name:` (not `tool:`); also accept string key for
    # goldrush-serialised payloads where atom keys become strings after gre.pairs().
    safe_register(:tool_result, fn payload ->
      tool =
        Map.get(payload, :name,
          Map.get(payload, "name",
            Map.get(payload, :tool,
              Map.get(payload, "tool", "unknown"))))

      # duration_ms is not present on tool_result events (it is on tool_call events);
      # default to 0 so the count is still incremented correctly.
      duration = Map.get(payload, :duration_ms, Map.get(payload, "duration_ms", 0))
      send(self_pid, {:daemon_event, {:tool_result, to_string(tool), duration}})
    end)

    # llm_response events from Agent.Loop emit:
    #   %{session_id:, duration_ms:, usage: %{input_tokens:, output_tokens:, ...}}
    # There is no top-level :provider field — provider is inferred from session state,
    # not forwarded in the event. We record :unknown as provider for the latency window
    # but still capture duration_ms and token usage faithfully.
    safe_register(:llm_response, fn payload ->
      provider =
        payload
        |> Map.get(:provider, Map.get(payload, "provider", :unknown))
        |> to_atom_provider()

      latency = Map.get(payload, :duration_ms, Map.get(payload, "duration_ms", 0))
      success = Map.get(payload, :success, Map.get(payload, "success", true))

      usage =
        payload
        |> Map.get(:usage, Map.get(payload, "usage", %{}))
        |> normalise_usage_map()

      send(self_pid, {:daemon_event, {:llm_response, provider, latency, success, usage}})
    end)

    # user_message events are not emitted anywhere in the current codebase.
    # The handler is kept so it fires automatically if/when the emission is added.
    # session_stats are also incremented from :llm_response to ensure the counters
    # are always live (see handle_event/1 below).
    safe_register(:user_message, fn payload ->
      session_id = Map.get(payload, :session_id, Map.get(payload, "session_id", "unknown"))
      send(self_pid, {:daemon_event, {:user_message, to_string(session_id)}})
    end)
  end

  # Accept both atom-key and string-key usage maps (goldrush serialises atom keys
  # to strings via gre.pairs/1 -> Map.new/1).
  defp normalise_usage_map(usage) when is_map(usage) do
    %{
      input_tokens:
        Map.get(usage, :input_tokens, Map.get(usage, "input_tokens", 0)),
      output_tokens:
        Map.get(usage, :output_tokens, Map.get(usage, "output_tokens", 0))
    }
  end

  defp normalise_usage_map(_), do: %{input_tokens: 0, output_tokens: 0}

  # Wraps Events.Bus.register_handler so that startup succeeds even when
  # Events.Bus is not running (e.g. mix test --no-start).
  defp safe_register(event_type, handler) do
    Daemon.Events.Bus.register_handler(event_type, handler)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp handle_event({:tool_result, tool_name, duration_ms}) do
    update_tool_execution(tool_name, duration_ms)
  end

  # 5-tuple emitted by the subscribe_to_events :llm_response handler (includes usage).
  defp handle_event({:llm_response, provider, latency_ms, success, usage}) do
    update_provider_latency(provider, latency_ms)
    update_provider_call_count(provider)
    unless success, do: update_provider_error_count(provider)
    update_token_stats(usage)
    # Increment messages_today via llm_response since :user_message events are not
    # currently emitted anywhere. Each LLM call corresponds to one user turn.
    update_messages_today()
  end

  # Legacy 4-tuple (emitted by direct record_provider_call/3 callers; no usage data).
  defp handle_event({:llm_response, provider, latency_ms, success}) do
    update_provider_latency(provider, latency_ms)
    update_provider_call_count(provider)
    unless success, do: update_provider_error_count(provider)
  end

  defp handle_event({:user_message, session_id}) do
    update_session_stats(session_id)
  end

  defp handle_event(_other), do: :ok

  # ── ETS State Helpers ────────────────────────────────────────────────

  defp seed_table do
    :ets.insert(:daemon_telemetry, {:tool_executions, %{}})
    :ets.insert(:daemon_telemetry, {:provider_latency, %{}})
    :ets.insert(:daemon_telemetry, {:provider_calls, %{}})
    :ets.insert(:daemon_telemetry, {:session_stats, %{turns_by_session: %{}, messages_today: 0, sessions_today: 0}})
    :ets.insert(:daemon_telemetry, {:token_stats, %{input_tokens: 0, output_tokens: 0}})
    :ets.insert(:daemon_telemetry, {:provider_errors, %{}})
    :ets.insert(:daemon_telemetry, {:noise_filter, %{filtered: 0, clarify: 0, pass: 0}})
    :ets.insert(:daemon_telemetry, {:signal_weights, empty_weight_buckets()})
  end

  # Tool execution stats: %{tool_name => %{count, total_ms, min_ms, max_ms, window}}
  # window is a circular buffer of the last 100 durations for p99 calculation.
  defp update_tool_execution(tool_name, duration_ms) do
    [{_, executions}] = :ets.lookup(:daemon_telemetry, :tool_executions)

    updated =
      Map.update(
        executions,
        tool_name,
        %{count: 1, total_ms: duration_ms, min_ms: duration_ms, max_ms: duration_ms,
          window: [duration_ms]},
        fn stats ->
          new_window =
            [duration_ms | stats.window]
            |> Enum.take(@latency_window)

          %{stats |
            count: stats.count + 1,
            total_ms: stats.total_ms + duration_ms,
            min_ms: min(stats.min_ms, duration_ms),
            max_ms: max(stats.max_ms, duration_ms),
            window: new_window
          }
        end
      )

    :ets.insert(:daemon_telemetry, {:tool_executions, updated})
  end

  defp update_provider_latency(provider, latency_ms) do
    [{_, latencies}] = :ets.lookup(:daemon_telemetry, :provider_latency)

    window =
      latencies
      |> Map.get(provider, [])
      |> then(fn existing ->
        new = [latency_ms | existing]
        Enum.take(new, @latency_window)
      end)

    :ets.insert(:daemon_telemetry, {:provider_latency, Map.put(latencies, provider, window)})
  end

  defp update_noise_filter(outcome) do
    [{_, counts}] = :ets.lookup(:daemon_telemetry, :noise_filter)
    updated = Map.update(counts, outcome, 1, &(&1 + 1))
    :ets.insert(:daemon_telemetry, {:noise_filter, updated})
  end

  defp update_signal_weight(weight) do
    [{_, buckets}] = :ets.lookup(:daemon_telemetry, :signal_weights)

    key =
      cond do
        weight < 0.2 -> :"0.0-0.2"
        weight < 0.5 -> :"0.2-0.5"
        weight < 0.8 -> :"0.5-0.8"
        true -> :"0.8-1.0"
      end

    updated = Map.update(buckets, key, 1, &(&1 + 1))
    :ets.insert(:daemon_telemetry, {:signal_weights, updated})
  end

  defp update_session_stats(session_id) do
    [{_, stats}] = :ets.lookup(:daemon_telemetry, :session_stats)

    is_new_session = not Map.has_key?(stats.turns_by_session, session_id)
    updated_turns = Map.update(stats.turns_by_session, session_id, 1, &(&1 + 1))

    updated = %{
      stats
      | turns_by_session: updated_turns,
        messages_today: stats.messages_today + 1,
        sessions_today: stats.sessions_today + if(is_new_session, do: 1, else: 0)
    }

    :ets.insert(:daemon_telemetry, {:session_stats, updated})
  end

  # Increments messages_today without requiring a session_id.
  # Called from the :llm_response handler as a fallback since :user_message
  # events are not currently emitted in the codebase.
  defp update_messages_today do
    [{_, stats}] = :ets.lookup(:daemon_telemetry, :session_stats)
    updated = %{stats | messages_today: stats.messages_today + 1}
    :ets.insert(:daemon_telemetry, {:session_stats, updated})
  end

  defp update_provider_call_count(provider) do
    [{_, calls}] = :ets.lookup(:daemon_telemetry, :provider_calls)
    updated = Map.update(calls, provider, 1, &(&1 + 1))
    :ets.insert(:daemon_telemetry, {:provider_calls, updated})
  end

  defp update_provider_error_count(provider) do
    [{_, errors}] = :ets.lookup(:daemon_telemetry, :provider_errors)
    updated = Map.update(errors, provider, 1, &(&1 + 1))
    :ets.insert(:daemon_telemetry, {:provider_errors, updated})
  end

  defp update_token_stats(%{input_tokens: inp, output_tokens: out}) do
    [{_, stats}] = :ets.lookup(:daemon_telemetry, :token_stats)

    updated = %{
      stats
      | input_tokens: stats.input_tokens + inp,
        output_tokens: stats.output_tokens + out
    }

    :ets.insert(:daemon_telemetry, {:token_stats, updated})
  end

  defp update_token_stats(_), do: :ok

  # ── Aggregation Helpers ──────────────────────────────────────────────

  defp build_metrics do
    keys = [:tool_executions, :provider_latency, :provider_calls, :provider_errors, :session_stats, :token_stats, :noise_filter, :signal_weights]

    Enum.reduce(keys, %{}, fn key, acc ->
      case :ets.lookup(:daemon_telemetry, key) do
        [{^key, value}] -> Map.put(acc, key, value)
        [] -> acc
      end
    end)
  end

  defp summarize_tool_executions(executions) do
    Map.new(executions, fn {tool_name, stats} ->
      {count, p99_ms, avg_ms} =
        if stats.count == 0 do
          {0, 0, 0.0}
        else
          sorted = Enum.sort(stats.window)
          window_count = length(sorted)
          p99_idx = max(0, round(window_count * 0.99) - 1)
          p99 = Enum.at(sorted, p99_idx, 0)
          avg = stats.total_ms / stats.count
          {stats.count, p99, Float.round(avg, 2)}
        end

      {tool_name, %{
        count: count,
        avg_ms: avg_ms,
        min_ms: stats.min_ms,
        max_ms: stats.max_ms,
        p99_ms: p99_ms
      }}
    end)
  end

  defp summarize_latencies(latencies_by_provider) do
    Map.new(latencies_by_provider, fn {provider, window} ->
      stats =
        if Enum.empty?(window) do
          %{avg_ms: 0, p99_ms: 0, count: 0}
        else
          sorted = Enum.sort(window)
          count = length(sorted)
          avg = Enum.sum(sorted) / count
          p99_idx = max(0, round(count * 0.99) - 1)
          p99 = Enum.at(sorted, p99_idx, 0)
          %{avg_ms: Float.round(avg, 2), p99_ms: p99, count: count}
        end

      {provider, stats}
    end)
  end

  defp empty_weight_buckets do
    %{
      "0.0-0.2": 0,
      "0.2-0.5": 0,
      "0.5-0.8": 0,
      "0.8-1.0": 0
    }
  end

  # ── Disk Persistence ─────────────────────────────────────────────────

  defp flush_to_disk do
    summary = get_summary()
    path = Path.expand("~/.daemon/metrics.json")

    payload =
      summary
      |> Map.put(:schema_version, 1)
      |> Map.put(:flushed_at, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Jason.encode!(pretty: true)

    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        case File.write(path, payload) do
          :ok ->
            Logger.debug("[Telemetry.Metrics] Metrics written to #{path}")

          {:error, reason} ->
            Logger.warning("[Telemetry.Metrics] Failed to write metrics: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("[Telemetry.Metrics] Cannot create ~/.osa dir: #{inspect(reason)}")
    end
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  # ── Utility ──────────────────────────────────────────────────────────

  defp to_atom_provider(provider) when is_atom(provider), do: provider

  defp to_atom_provider(provider) when is_binary(provider) do
    try do
      String.to_existing_atom(provider)
    rescue
      ArgumentError -> :unknown
    end
  end

  defp to_atom_provider(_), do: :unknown
end
