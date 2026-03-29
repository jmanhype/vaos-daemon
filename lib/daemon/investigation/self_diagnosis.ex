defmodule Daemon.Investigation.SelfDiagnosis do
  @moduledoc """
  Self-diagnosis loop: polls CrashLearner for recurring failure pitfalls,
  uses the investigate tool to research root causes, and recommends or
  takes corrective actions (strategy updates, knowledge graph annotations).

  Safety mechanisms:
  - 1-hour cooldown per pattern hash (no re-investigating the same failure)
  - Max 1 active investigation at a time (circuit breaker)
  - Investigation failures are rescued and logged, never sent to CrashLearner
  - Always uses "standard" depth (no deep research pipelines)
  - Corrective actions that modify strategy go through Governance.Approvals
  - Graceful degradation if CrashLearner process not found
  """
  use GenServer
  require Logger

  alias Vaos.Ledger.ML.CrashLearner
  alias Daemon.Events.Bus

  @poll_interval_ms 5 * 60_000
  @initial_delay_ms 30_000
  @cooldown_seconds 3_600
  @max_findings 50
  @self_diagnosis_prefix "Why does this error occur"

  # -- Public API ----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the self-diagnosis topic prefix used to identify self-diagnosis investigations."
  def self_diagnosis_prefix, do: @self_diagnosis_prefix

  @doc "Returns current findings from the rolling buffer."
  def get_findings do
    GenServer.call(__MODULE__, :get_findings)
  end

  @doc """
  Trigger a diagnosis for a specific tool failure pattern.

  Called by DecisionLedger escalation when session failures exceed thresholds
  AND the failure rate is significantly above historical average.

  `pattern_key` is e.g. "shell_execute:git", `context` is a map with
  `:session_failures`, `:historical_rate`, `:session_rate`, `:recent_errors`.
  """
  @spec trigger_diagnosis(String.t(), map()) :: :ok | :cooldown
  def trigger_diagnosis(pattern_key, context \\ %{}) do
    GenServer.cast(__MODULE__, {:external_diagnosis, pattern_key, context})
  end

  # -- GenServer callbacks -------------------------------------------------

  @impl true
  def init(_opts) do
    Process.send_after(self(), :poll, @initial_delay_ms)
    Logger.info("[SelfDiagnosis] Started, first poll in #{div(@initial_delay_ms, 1000)}s")

    {:ok, %{
      timer_ref: nil,
      investigated_patterns: %{},
      active_task: nil,
      findings: [],
      last_pitfall_count: 0
    }}
  end

  @impl true
  def handle_call(:get_findings, _from, state) do
    {:reply, state.findings, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = check_for_new_pitfalls(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info({:diagnosis_complete, pattern_hash, result}, state) do
    state = record_finding(state, pattern_hash, result)
    state = maybe_take_action(state, result)
    {:noreply, %{state | active_task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active_task: ref} = state) do
    Logger.warning("[SelfDiagnosis] Investigation task crashed, resetting active_task")
    {:noreply, %{state | active_task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:external_diagnosis, pattern_key, context}, state) do
    hash = :erlang.phash2({"external", pattern_key})
    now = DateTime.utc_now()

    cond do
      state.active_task != nil ->
        Logger.debug("[SelfDiagnosis] Skipping external trigger for #{pattern_key} — investigation already in progress")
        {:noreply, state}

      recently_investigated_hash?(state, hash, now) ->
        Logger.debug("[SelfDiagnosis] Skipping external trigger for #{pattern_key} — cooldown active")
        {:noreply, state}

      true ->
        state = run_external_diagnosis(state, pattern_key, context, hash)
        {:noreply, state}
    end
  end

  # -- Poll logic ----------------------------------------------------------

  defp check_for_new_pitfalls(state) do
    case safe_get_pitfalls() do
      {:ok, pitfalls} ->
        current_count = length(pitfalls)

        if current_count > state.last_pitfall_count do
          Logger.info("[SelfDiagnosis] New pitfalls detected (#{state.last_pitfall_count} -> #{current_count})")
          state = %{state | last_pitfall_count: current_count}
          maybe_investigate_pitfall(state, pitfalls)
        else
          %{state | last_pitfall_count: current_count}
        end

      :skip ->
        state
    end
  end

  defp safe_get_pitfalls do
    try do
      case CrashLearner.get_pitfalls(:daemon_crash_learner) do
        {:ok, pitfalls} -> {:ok, pitfalls}
        _ -> :skip
      end
    rescue
      _ -> :skip
    catch
      :exit, _ -> :skip
    end
  end

  defp maybe_investigate_pitfall(%{active_task: ref} = state, _pitfalls) when not is_nil(ref) do
    Logger.debug("[SelfDiagnosis] Skipping — investigation already in progress")
    state
  end

  defp maybe_investigate_pitfall(state, pitfalls) do
    now = DateTime.utc_now()

    # Find first pitfall with count >= 3 that hasn't been investigated recently
    candidate = Enum.find(pitfalls, fn p ->
      count = Map.get(p, :count, 0)
      count >= 3 and not recently_investigated?(state, p, now)
    end)

    case candidate do
      nil -> state
      pitfall -> run_diagnosis(state, pitfall)
    end
  end

  defp recently_investigated_hash?(state, hash, now) do
    case Map.get(state.investigated_patterns, hash) do
      nil -> false
      last_at -> DateTime.diff(now, last_at, :second) < @cooldown_seconds
    end
  end

  defp recently_investigated?(state, pitfall, now) do
    hash = pattern_hash(pitfall)

    case Map.get(state.investigated_patterns, hash) do
      nil -> false
      last_at ->
        diff = DateTime.diff(now, last_at, :second)
        diff < @cooldown_seconds
    end
  end

  # -- Investigation spawning ----------------------------------------------

  defp run_diagnosis(state, pitfall) do
    hash = pattern_hash(pitfall)
    summary = Map.get(pitfall, :summary, "unknown failure")

    Logger.info("[SelfDiagnosis] Spawning investigation for pitfall: #{summary}")

    topic = "#{@self_diagnosis_prefix} in the VAOS daemon investigation pipeline: #{summary}. " <>
            "What is the root cause and how can the system automatically prevent or work around it?"

    parent = self()

    task = Task.async(fn ->
      result = try do
        case Daemon.Tools.Builtins.Investigate.execute(%{"topic" => topic, "depth" => "standard"}) do
          {:ok, investigation_result} -> {:ok, investigation_result}
          {:error, reason} -> {:error, reason}
          other -> {:ok, other}
        end
      rescue
        e ->
          Logger.warning("[SelfDiagnosis] Investigation failed (rescued): #{inspect(e)}")
          {:error, inspect(e)}
      end

      send(parent, {:diagnosis_complete, hash, result})
      result
    end)

    now = DateTime.utc_now()
    investigated = Map.put(state.investigated_patterns, hash, now)

    %{state |
      active_task: task.ref,
      investigated_patterns: investigated
    }
  end

  # -- External diagnosis (triggered by DecisionLedger escalation) ----------

  defp run_external_diagnosis(state, pattern_key, context, hash) do
    session_failures = Map.get(context, :session_failures, 0)
    historical_rate = Map.get(context, :historical_rate, "unknown")
    session_rate = Map.get(context, :session_rate, "unknown")
    recent_errors = Map.get(context, :recent_errors, [])

    errors_str = recent_errors |> Enum.take(3) |> Enum.join("; ")

    Logger.info("[SelfDiagnosis] External trigger: #{pattern_key} " <>
      "(#{session_failures} session failures, session_rate=#{session_rate}%, historical=#{historical_rate}%)")

    topic = "#{@self_diagnosis_prefix}: tool '#{pattern_key}' is failing #{session_failures} times " <>
            "consecutively in the current session (#{session_rate}% failure rate vs #{historical_rate}% historical). " <>
            "Recent errors: #{errors_str}. " <>
            "What is the root cause and how can the system automatically prevent or work around it?"

    parent = self()

    task = Task.async(fn ->
      result = try do
        case Daemon.Tools.Builtins.Investigate.execute(%{"topic" => topic, "depth" => "standard"}) do
          {:ok, investigation_result} -> {:ok, investigation_result}
          {:error, reason} -> {:error, reason}
          other -> {:ok, other}
        end
      rescue
        e ->
          Logger.warning("[SelfDiagnosis] External investigation failed (rescued): #{inspect(e)}")
          {:error, inspect(e)}
      end

      send(parent, {:diagnosis_complete, hash, result})
      result
    end)

    now = DateTime.utc_now()
    investigated = Map.put(state.investigated_patterns, hash, now)

    %{state |
      active_task: task.ref,
      investigated_patterns: investigated
    }
  end

  # -- Finding storage -----------------------------------------------------

  defp record_finding(state, pattern_hash, result) do
    finding = %{
      pattern_hash: pattern_hash,
      result: result,
      timestamp: DateTime.utc_now()
    }

    findings = Enum.take([finding | state.findings], @max_findings)
    %{state | findings: findings}
  end

  # -- Corrective actions --------------------------------------------------

  defp maybe_take_action(state, {:ok, result}) when is_map(result) do
    # Store finding triple in knowledge graph
    store_finding_triple(result)

    direction = Map.get(result, :direction) || Map.get(result, "direction")

    case direction do
      dir when dir in ["supporting", :supporting] ->
        suggest_corrections(result)

      _ ->
        Logger.info("[SelfDiagnosis] Insufficient evidence for corrective action")
    end

    # Emit system event
    emit_diagnosis_event(result)
    state
  end

  defp maybe_take_action(state, {:error, reason}) do
    Logger.info("[SelfDiagnosis] Investigation returned error: #{inspect(reason)}")
    emit_diagnosis_event(%{status: :error, reason: reason})
    state
  end

  defp maybe_take_action(state, _other) do
    Logger.info("[SelfDiagnosis] Investigation returned unexpected result")
    state
  end

  defp store_finding_triple(result) do
    try do
      store = "osa_default"
      finding_id = "self_diagnosis:#{:erlang.phash2(result)}_#{System.system_time(:millisecond)}"
      topic = Map.get(result, :topic) || Map.get(result, "topic") || "unknown"
      direction = to_string(Map.get(result, :direction) || Map.get(result, "direction") || "unknown")

      triples = [
        {finding_id, "rdf:type", "vaos:SelfDiagnosisFinding"},
        {finding_id, "vaos:topic", topic},
        {finding_id, "vaos:direction", direction},
        {finding_id, "vaos:timestamp", DateTime.utc_now() |> DateTime.to_iso8601()}
      ]

      for triple <- triples do
        MiosaKnowledge.assert(store, triple)
      end
    rescue
      e ->
        Logger.warning("[SelfDiagnosis] Failed to store finding triple: #{inspect(e)}")
    end
  end

  defp suggest_corrections(result) do
    summary = Map.get(result, :summary) || Map.get(result, "summary") || ""
    summary_lower = String.downcase(summary)

    cond do
      String.contains?(summary_lower, "rate limit") or String.contains?(summary_lower, "timeout") ->
        Logger.info("[SelfDiagnosis] Suggesting strategy adjustment for rate limit/timeout issue")
        try do
          Daemon.Governance.Approvals.create(%{
            type: "strategy_change",
            title: "SelfDiagnosis: rate limit/timeout adjustment suggested",
            description: "Self-diagnosis found recurring rate limit or timeout failures. " <>
                         "Consider adjusting retry intervals or concurrency parameters. " <>
                         "Finding: #{String.slice(summary, 0, 500)}",
            requested_by: "self_diagnosis",
            context: %{"source" => "self_diagnosis", "finding_summary" => summary}
          })
        rescue
          _ -> :ok
        end

      String.contains?(summary_lower, "missing") or String.contains?(summary_lower, "capability") ->
        Logger.info("[SelfDiagnosis] Suggesting new skill creation for missing capability")

      true ->
        Logger.info("[SelfDiagnosis] Finding recorded, no specific corrective action identified")
    end
  end

  defp emit_diagnosis_event(result) do
    try do
      Bus.emit(:system_event, %{
        event: :self_diagnosis_complete,
        result: result,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    rescue
      _ -> :ok
    end
  end

  # -- Helpers -------------------------------------------------------------

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp pattern_hash(pitfall) do
    pattern = Map.get(pitfall, :pattern, Map.get(pitfall, :summary, ""))
    :erlang.phash2(pattern)
  end
end
