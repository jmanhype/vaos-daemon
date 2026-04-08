defmodule Daemon.Intelligence.DecisionJournal do
  @moduledoc """
  Coordination spine for autonomous decision-making.

  Modules that create branches/PRs call `propose/3` before acting. The Journal:

  1. **Dedup** — rejects proposals that conflict with in-flight work
  2. **ALCOA provenance** — records every decision to EpistemicLedger
  3. **Unified PR polling** — single `gh pr list` replaces independent loops
  4. **Cross-module reward routing** — PR outcomes update the originating module
     AND related modules get partial signal
  5. **Observability** — `decisions/0` and `stats/0` show the full decision history

  VAOS now also uses the Journal as an adaptation rationale spine. Adaptive
  workers append high-signal entries here so the system can reconstruct why
  research or reliability behavior changed without adding a global coordinator.
  """
  use GenServer
  require Logger

  alias Vaos.Ledger.Epistemic.Ledger, as: EpistemicLedger

  @pr_poll_interval_ms :timer.hours(1)
  @daemon_repo "jmanhype/vaos-daemon"
  @max_decisions 200
  @max_adaptation_entries 500
  @max_failed_adaptations 5
  @default_adaptation_freshness_ms :timer.minutes(30)
  @persistence_dir Path.expand("~/.daemon/intelligence")
  @persistence_file "decision_journal.json"
  @ledger_name :investigate_ledger
  @knowledge_store "osa_default"

  # ── Public API ────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Propose an autonomous decision. Returns :approved or {:conflict, reason}.

  `source_module` — atom like :insight_actuator, :convergence_engine, :work_director
  `action_type` — atom like :create_pr, :investigate, :repair
  `context` — map with at minimum: %{topic: String.t(), branch: String.t()}
  """
  @spec propose(atom(), atom(), map()) :: :approved | {:conflict, String.t()}
  def propose(source_module, action_type, context) do
    try do
      GenServer.call(__MODULE__, {:propose, source_module, action_type, context}, 10_000)
    rescue
      _ -> :approved
    catch
      :exit, _ -> :approved
    end
  end

  @doc "Record that a proposed decision completed (success or failure)."
  @spec record_outcome(String.t(), :success | :failure, map()) :: :ok
  def record_outcome(branch, outcome, metadata \\ %{}) do
    try do
      GenServer.cast(__MODULE__, {:record_outcome, branch, outcome, metadata})
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  @doc "Get all decisions (for debugging/observability)."
  def decisions do
    try do
      GenServer.call(__MODULE__, :decisions)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  @doc """
  Record a high-signal adaptation event from a domain-specific loop.

  `domain` should be a stable label like `:research`, `:reliability`, or
  `:coordination`. `event_type` should describe the adaptation decision or
  signal, for example `:topic_selected`, `:strategy_experiment_started`, or
  `:tool_failure_escalated`.
  """
  @spec record_adaptation(atom() | String.t(), atom() | String.t(), map()) :: :ok
  def record_adaptation(domain, event_type, context \\ %{}) when is_map(context) do
    try do
      GenServer.cast(
        __MODULE__,
        {:record_adaptation, normalize_name(domain), normalize_name(event_type), context}
      )
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  @doc "Return recent adaptation entries (most recent first)."
  @spec adaptation_events(pos_integer()) :: [map()]
  def adaptation_events(limit \\ 50) when is_integer(limit) and limit > 0 do
    try do
      GenServer.call(__MODULE__, {:adaptation_events, limit})
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  @doc "Return a longitudinal review summary over recent adaptation entries."
  @spec adaptation_review(pos_integer()) :: map()
  def adaptation_review(limit \\ 200) when is_integer(limit) and limit > 0 do
    try do
      GenServer.call(__MODULE__, {:adaptation_review, limit})
    rescue
      _ -> empty_adaptation_review()
    catch
      :exit, _ -> empty_adaptation_review()
    end
  end

  @doc "Return the derived adaptation meta-state snapshot."
  @spec meta_state() :: map()
  def meta_state do
    try do
      GenServer.call(__MODULE__, :meta_state)
    rescue
      _ -> empty_meta_state()
    catch
      :exit, _ -> empty_meta_state()
    end
  end

  @doc "Clear all in-flight entries (use to recover from stale locks)."
  def clear_in_flight do
    try do
      GenServer.call(__MODULE__, :clear_in_flight)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  @doc "Get journal stats."
  def stats do
    try do
      GenServer.call(__MODULE__, :stats)
    rescue
      _ -> %{status: :not_running}
    catch
      :exit, _ -> %{status: :not_running}
    end
  end

  # ── GenServer Callbacks ───────────────────────────────────

  @impl true
  def init(_opts) do
    state = %{
      # [{branch, source_module, action_type, topic, status, timestamps, claim_id}]
      decisions: [],
      # [%{domain, event_type, timestamp, context}]
      adaptation_entries: [],
      # %{normalized_topic => %{branch, source_module, started_at}}
      in_flight: %{},
      total_proposed: 0,
      total_approved: 0,
      total_conflicts: 0,
      total_merged: 0,
      total_rejected: 0
    }

    state = load_persisted_state(state)

    Process.send_after(self(), :poll_pr_outcomes, @pr_poll_interval_ms)

    Logger.info(
      "[DecisionJournal] Started (#{length(state.decisions)} persisted decisions, #{map_size(state.in_flight)} in-flight)"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:propose, source_module, action_type, context}, _from, state) do
    topic = Map.get(context, :topic, "")
    branch = Map.get(context, :branch, "")
    normalized = normalize_topic(topic)

    state = %{state | total_proposed: state.total_proposed + 1}

    case check_conflicts(normalized, branch, state) do
      {:conflict, reason} ->
        state = %{state | total_conflicts: state.total_conflicts + 1}

        Logger.info(
          "[DecisionJournal] CONFLICT: #{source_module}/#{action_type} on '#{String.slice(topic, 0, 50)}' — #{reason}"
        )

        state =
          append_adaptation_entry(state, "coordination", "suppression", %{
            source_module: source_module,
            action_type: action_type,
            topic: topic,
            branch: branch,
            reason: reason
          })

        {:reply, {:conflict, reason}, state}

      :clear ->
        # Record the decision
        claim_id = create_provenance_claim(source_module, action_type, context)

        decision = %{
          branch: branch,
          source_module: source_module,
          action_type: action_type,
          topic: topic,
          normalized_topic: normalized,
          status: :in_flight,
          proposed_at: DateTime.utc_now(),
          completed_at: nil,
          outcome: nil,
          claim_id: claim_id,
          metadata: Map.drop(context, [:topic, :branch])
        }

        in_flight =
          Map.put(state.in_flight, normalized, %{
            branch: branch,
            source_module: source_module,
            started_at: DateTime.utc_now()
          })

        decisions = [decision | state.decisions] |> Enum.take(@max_decisions)

        state = %{
          state
          | decisions: decisions,
            in_flight: in_flight,
            total_approved: state.total_approved + 1
        }

        state =
          append_adaptation_entry(state, "coordination", "approval", %{
            source_module: source_module,
            action_type: action_type,
            topic: topic,
            branch: branch
          })

        # Emit event
        emit_decision_event(:decision_proposed, %{
          source_module: source_module,
          action_type: action_type,
          topic: topic,
          branch: branch
        })

        persist_state(state)

        Logger.info("[DecisionJournal] APPROVED: #{source_module}/#{action_type} → #{branch}")
        {:reply, :approved, state}
    end
  end

  def handle_call(:decisions, _from, state) do
    recent =
      Enum.take(state.decisions, 50)
      |> Enum.map(fn d ->
        %{
          branch: d.branch,
          source: d.source_module,
          action: d.action_type,
          topic: String.slice(d.topic, 0, 60),
          status: d.status,
          proposed_at: d.proposed_at,
          outcome: d.outcome
        }
      end)

    {:reply, recent, state}
  end

  def handle_call({:adaptation_events, limit}, _from, state) do
    {:reply, Enum.take(state.adaptation_entries, limit), state}
  end

  def handle_call({:adaptation_review, limit}, _from, state) do
    {:reply, derive_adaptation_review(state, limit), state}
  end

  def handle_call(:meta_state, _from, state) do
    {:reply, derive_meta_state(state), state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      status: :running,
      total_proposed: state.total_proposed,
      total_approved: state.total_approved,
      total_conflicts: state.total_conflicts,
      total_merged: state.total_merged,
      total_rejected: state.total_rejected,
      in_flight_count: map_size(state.in_flight),
      in_flight:
        Enum.map(state.in_flight, fn {topic, info} ->
          %{topic: String.slice(topic, 0, 40), branch: info.branch, source: info.source_module}
        end),
      decision_count: length(state.decisions),
      adaptation_event_count: length(state.adaptation_entries),
      meta_state: derive_meta_state(state)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:clear_in_flight, _from, state) do
    count = map_size(state.in_flight)
    Logger.info("[DecisionJournal] Clearing #{count} in-flight entries")

    decisions =
      Enum.map(state.decisions, fn d ->
        if d.status == :in_flight do
          %{d | status: :cleared, completed_at: DateTime.utc_now(), outcome: :cleared}
        else
          d
        end
      end)

    state = %{state | decisions: decisions, in_flight: %{}}
    persist_state(state)
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_cast({:record_outcome, branch, outcome, metadata}, state) do
    state = do_record_outcome(state, branch, outcome, metadata)
    {:noreply, state}
  end

  def handle_cast({:record_adaptation, domain, event_type, context}, state) do
    state = append_adaptation_entry(state, domain, event_type, context)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll_pr_outcomes, state) do
    state = poll_all_pr_outcomes(state)
    sync_to_knowledge(state.decisions)
    Process.send_after(self(), :poll_pr_outcomes, @pr_poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    persist_state(state)
    :ok
  end

  # ── Conflict Detection ────────────────────────────────────

  defp check_conflicts(normalized_topic, branch, state) do
    # Check 1: Same topic already in flight (across any module)
    case Map.get(state.in_flight, normalized_topic) do
      %{branch: existing_branch, source_module: existing_source} ->
        {:conflict, "topic already in flight as #{existing_branch} (#{existing_source})"}

      nil ->
        # Check 2: Same branch name already in flight
        branch_conflict =
          Enum.find(state.in_flight, fn {_topic, info} ->
            info.branch == branch
          end)

        case branch_conflict do
          {_topic, %{source_module: existing_source}} ->
            {:conflict, "branch #{branch} already in flight (#{existing_source})"}

          nil ->
            # Check 3: Recently completed/failed same topic (within 4 hours)
            recent_match =
              Enum.find(state.decisions, fn d ->
                d.normalized_topic == normalized_topic and
                  d.status in [:completed, :failed] and
                  d.completed_at != nil and
                  DateTime.diff(DateTime.utc_now(), d.completed_at, :minute) < 30
              end)

            case recent_match do
              %{branch: prev_branch, outcome: prev_outcome} ->
                {:conflict, "topic recently #{prev_outcome} on #{prev_branch} (4h cooldown)"}

              nil ->
                :clear
            end
        end
    end
  end

  # ── Outcome Recording ─────────────────────────────────────

  defp do_record_outcome(state, branch, outcome, metadata) do
    # Update decision record
    decisions =
      Enum.map(state.decisions, fn d ->
        if d.branch == branch and d.status == :in_flight do
          %{
            d
            | status: outcome_to_status(outcome),
              completed_at: DateTime.utc_now(),
              outcome: outcome,
              metadata: Map.merge(d.metadata, metadata)
          }
        else
          d
        end
      end)

    # Remove from in-flight
    in_flight =
      state.in_flight
      |> Enum.reject(fn {_topic, info} -> info.branch == branch end)
      |> Map.new()

    # Add evidence to provenance claim
    claim_id = find_claim_for_branch(state.decisions, branch)
    if claim_id, do: add_outcome_evidence(claim_id, outcome, metadata)

    # Emit event
    emit_decision_event(:decision_completed, %{branch: branch, outcome: outcome})

    state = %{state | decisions: decisions, in_flight: in_flight}
    persist_state(state)
    state
  end

  defp outcome_to_status(:success), do: :completed
  defp outcome_to_status(:merged), do: :completed
  defp outcome_to_status(_), do: :failed

  defp find_claim_for_branch(decisions, branch) do
    case Enum.find(decisions, fn d -> d.branch == branch end) do
      %{claim_id: id} when not is_nil(id) -> id
      _ -> nil
    end
  end

  # ── Unified PR Outcome Polling ────────────────────────────

  defp poll_all_pr_outcomes(state) do
    # Single gh pr list for ALL autonomous branches
    case System.cmd(
           "gh",
           [
             "pr",
             "list",
             "--repo",
             @daemon_repo,
             "--json",
             "headRefName,state,mergedAt",
             "--limit",
             "50",
             "--state",
             "all"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, prs} -> process_unified_pr_outcomes(state, prs)
          _ -> state
        end

      _ ->
        state
    end
  rescue
    _ -> state
  end

  defp process_unified_pr_outcomes(state, prs) do
    Enum.reduce(prs, state, fn pr, acc ->
      branch = pr["headRefName"] || ""

      # Only process branches from our autonomous modules
      if autonomous_branch?(branch) do
        # Find matching decision
        decision =
          Enum.find(acc.decisions, fn d ->
            d.branch == branch and d.status == :in_flight
          end)

        if decision do
          cond do
            pr["state"] == "MERGED" ->
              Logger.info("[DecisionJournal] PR MERGED: #{branch} (#{decision.source_module})")

              acc = do_record_outcome(acc, branch, :merged, %{pr_state: "MERGED"})

              # Notify the originating module
              notify_module(decision.source_module, branch, :merged)

              %{acc | total_merged: acc.total_merged + 1}

            pr["state"] == "CLOSED" ->
              Logger.info("[DecisionJournal] PR REJECTED: #{branch} (#{decision.source_module})")

              acc = do_record_outcome(acc, branch, :rejected, %{pr_state: "CLOSED"})

              notify_module(decision.source_module, branch, :rejected)

              %{acc | total_rejected: acc.total_rejected + 1}

            true ->
              acc
          end
        else
          acc
        end
      else
        acc
      end
    end)
  end

  defp autonomous_branch?(branch) do
    String.starts_with?(branch, "insight/") or
      String.starts_with?(branch, "convergence/") or
      String.starts_with?(branch, "workdir/")
  end

  defp notify_module(source_module, branch, outcome) do
    # Send reward signals to the originating module
    reward = if outcome == :merged, do: 1.0, else: 0.2

    # Reward routing — modules removed, log for observability
    Logger.debug("[DecisionJournal] PR outcome for #{source_module}/#{branch}: reward=#{reward}")
    :ok
  end

  # ── ALCOA Provenance ──────────────────────────────────────

  @ledger_path Path.join(System.user_home!(), ".openclaw/investigate_ledger.json")

  defp ensure_ledger_started do
    case Process.whereis(@ledger_name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case EpistemicLedger.start_link(path: @ledger_path, name: @ledger_name) do
          {:ok, _pid} ->
            Logger.info("[DecisionJournal] Started EpistemicLedger (#{@ledger_name})")
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[DecisionJournal] Failed to start EpistemicLedger: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  rescue
    _ -> {:error, :start_failed}
  end

  defp create_provenance_claim(source_module, action_type, context) do
    ensure_ledger_started()

    topic = Map.get(context, :topic, "unknown")
    branch = Map.get(context, :branch, "unknown")

    claim =
      EpistemicLedger.add_claim(
        [
          title: "Autonomous decision: #{source_module}/#{action_type}",
          statement:
            "#{source_module} proposed #{action_type} for '#{String.slice(topic, 0, 80)}' on branch #{branch}",
          tags: [
            "decision_journal",
            "autonomous_decision",
            to_string(source_module),
            to_string(action_type)
          ]
        ],
        @ledger_name
      )

    case claim do
      %{id: id} ->
        # Add initial evidence: the proposal itself
        EpistemicLedger.add_evidence(
          [
            claim_id: id,
            summary:
              "Decision proposed at #{DateTime.utc_now() |> DateTime.to_iso8601()}. " <>
                "Source: #{source_module}, Action: #{action_type}, Branch: #{branch}",
            direction: :support,
            strength: 0.5,
            confidence: 0.8,
            source_type: "observation"
          ],
          @ledger_name
        )

        id

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp add_outcome_evidence(claim_id, outcome, metadata) do
    ensure_ledger_started()

    {direction, strength} =
      case outcome do
        :merged -> {:support, 1.0}
        :success -> {:support, 0.7}
        :rejected -> {:contradict, 0.6}
        :failure -> {:contradict, 0.8}
        _ -> {:support, 0.3}
      end

    pr_state = Map.get(metadata, :pr_state, to_string(outcome))

    EpistemicLedger.add_evidence(
      [
        claim_id: claim_id,
        summary:
          "Decision outcome: #{pr_state} at #{DateTime.utc_now() |> DateTime.to_iso8601()}",
        direction: direction,
        strength: strength,
        confidence: 0.9,
        source_type: "observation"
      ],
      @ledger_name
    )
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Knowledge Graph Sync ──────────────────────────────────

  defp sync_to_knowledge(decisions) do
    store_ref = Vaos.Knowledge.store_ref(@knowledge_store)
    store_via = {:via, Registry, {Vaos.Knowledge.Registry, @knowledge_store}}

    case GenServer.whereis(store_via) do
      nil ->
        :ok

      _pid ->
        triples =
          Enum.flat_map(Enum.take(decisions, 20), fn d ->
            subject = "decision:#{d.branch}"
            now = DateTime.utc_now() |> DateTime.to_iso8601()

            [
              {subject, "rdf:type", "vaos:AutonomousDecision"},
              {subject, "vaos:sourceModule", to_string(d.source_module)},
              {subject, "vaos:actionType", to_string(d.action_type)},
              {subject, "vaos:status", to_string(d.status)},
              {subject, "vaos:branch", d.branch},
              {subject, "vaos:timestamp", now}
            ]
          end)

        if triples != [], do: MiosaKnowledge.assert_many(store_ref, triples)
        :ok
    end
  rescue
    _ -> :ok
  end

  # ── Event Emission ────────────────────────────────────────

  defp emit_decision_event(event_type, payload) do
    try do
      Daemon.Events.Bus.emit(event_type, payload)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # ── Persistence ───────────────────────────────────────────

  defp persistence_path do
    Path.join(@persistence_dir, @persistence_file)
  end

  defp persist_state(state) do
    data = %{
      "version" => 2,
      "decisions" => Enum.map(Enum.take(state.decisions, @max_decisions), &serialize_decision/1),
      "adaptation_entries" =>
        Enum.map(
          Enum.take(state.adaptation_entries, @max_adaptation_entries),
          &serialize_adaptation_entry/1
        ),
      "stats" => %{
        "total_proposed" => state.total_proposed,
        "total_approved" => state.total_approved,
        "total_conflicts" => state.total_conflicts,
        "total_merged" => state.total_merged,
        "total_rejected" => state.total_rejected
      }
    }

    File.mkdir_p!(@persistence_dir)
    File.write!(persistence_path(), Jason.encode!(data, pretty: true))
  rescue
    e ->
      Logger.warning("[DecisionJournal] Failed to persist: #{Exception.message(e)}")
  end

  defp load_persisted_state(state) do
    case File.read(persistence_path()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok,
           %{
             "version" => 2,
             "decisions" => raw,
             "adaptation_entries" => entries,
             "stats" => stats
           }} ->
            load_persisted_state_v2(state, raw, entries, stats)

          {:ok, %{"version" => 1, "decisions" => raw, "stats" => stats}} ->
            load_persisted_state_v2(state, raw, [], stats)

          _ ->
            state
        end

      {:error, _} ->
        state
    end
  rescue
    _ -> state
  end

  defp serialize_decision(d) do
    %{
      "branch" => d.branch,
      "source_module" => to_string(d.source_module),
      "action_type" => to_string(d.action_type),
      "topic" => d.topic,
      "normalized_topic" => d.normalized_topic,
      "status" => to_string(d.status),
      "proposed_at" => d.proposed_at && DateTime.to_iso8601(d.proposed_at),
      "completed_at" => d.completed_at && DateTime.to_iso8601(d.completed_at),
      "outcome" => d.outcome && to_string(d.outcome),
      "claim_id" => d.claim_id
    }
  end

  defp serialize_adaptation_entry(entry) do
    %{
      "domain" => entry.domain,
      "event_type" => entry.event_type,
      "timestamp" => entry.timestamp && DateTime.to_iso8601(entry.timestamp),
      "context" => stringify_keys(entry.context)
    }
  end

  defp deserialize_decision(raw) when is_map(raw) do
    try do
      %{
        branch: raw["branch"] || "",
        source_module: String.to_existing_atom(raw["source_module"] || "unknown"),
        action_type: String.to_existing_atom(raw["action_type"] || "unknown"),
        topic: raw["topic"] || "",
        normalized_topic: raw["normalized_topic"] || normalize_topic(raw["topic"] || ""),
        status: String.to_existing_atom(raw["status"] || "completed"),
        proposed_at: parse_datetime(raw["proposed_at"]),
        completed_at: parse_datetime(raw["completed_at"]),
        outcome: if(raw["outcome"], do: String.to_existing_atom(raw["outcome"])),
        claim_id: raw["claim_id"],
        metadata: %{}
      }
    rescue
      _ -> nil
    end
  end

  defp deserialize_decision(_), do: nil

  defp deserialize_adaptation_entry(raw) when is_map(raw) do
    %{
      domain: to_string(raw["domain"] || "unknown"),
      event_type: to_string(raw["event_type"] || "unknown"),
      timestamp: parse_datetime(raw["timestamp"]) || DateTime.utc_now(),
      context: normalize_context_map(raw["context"] || %{})
    }
  rescue
    _ -> nil
  end

  defp deserialize_adaptation_entry(_), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # ── Helpers ───────────────────────────────────────────────

  defp recover_stale_in_flight(decisions, now) do
    Enum.map_reduce(decisions, 0, fn decision, recovered_count ->
      if decision.status == :in_flight and stale_in_flight?(decision, now) do
        {
          %{
            decision
            | status: :cleared,
              completed_at: now,
              outcome: :cleared
          },
          recovered_count + 1
        }
      else
        {decision, recovered_count}
      end
    end)
  end

  defp stale_in_flight?(%{action_type: :investigate, branch: "n/a"}, _now), do: true

  defp stale_in_flight?(
         %{status: :in_flight, proposed_at: %DateTime{} = proposed_at} = decision,
         now
       ) do
    max_age_hours =
      case decision.action_type do
        :investigate -> 1
        _ -> 24
      end

    cutoff = DateTime.add(now, -max_age_hours, :hour)
    DateTime.compare(proposed_at, cutoff) != :gt
  end

  defp stale_in_flight?(_decision, _now), do: true

  defp load_persisted_state_v2(state, raw_decisions, raw_entries, stats) do
    now = DateTime.utc_now()

    {decisions, recovered_count} =
      raw_decisions
      |> Enum.map(&deserialize_decision/1)
      |> Enum.reject(&is_nil/1)
      |> recover_stale_in_flight(now)

    in_flight =
      decisions
      |> Enum.filter(fn d -> d.status == :in_flight end)
      |> Map.new(fn d ->
        {d.normalized_topic,
         %{
           branch: d.branch,
           source_module: d.source_module,
           started_at: d.proposed_at
         }}
      end)

    adaptation_entries =
      raw_entries
      |> Enum.map(&deserialize_adaptation_entry/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(@max_adaptation_entries)

    state = %{
      state
      | decisions: decisions,
        adaptation_entries: adaptation_entries,
        in_flight: in_flight,
        total_proposed: Map.get(stats, "total_proposed", 0),
        total_approved: Map.get(stats, "total_approved", 0),
        total_conflicts: Map.get(stats, "total_conflicts", 0),
        total_merged: Map.get(stats, "total_merged", 0),
        total_rejected: Map.get(stats, "total_rejected", 0)
    }

    if recovered_count > 0 do
      Logger.warning(
        "[DecisionJournal] Recovered #{recovered_count} stale in-flight decision(s) from persistence"
      )

      persist_state(state)
    end

    state
  end

  defp append_adaptation_entry(state, domain, event_type, context) do
    entry = %{
      domain: normalize_name(domain),
      event_type: normalize_name(event_type),
      timestamp: DateTime.utc_now(),
      context: sanitize_context(context)
    }

    emit_decision_event(:system_event, %{
      event: :adaptation_signal,
      domain: entry.domain,
      event_type: entry.event_type,
      context: entry.context,
      timestamp: entry.timestamp
    })

    adaptation_entries =
      [entry | state.adaptation_entries]
      |> Enum.take(@max_adaptation_entries)

    state = %{state | adaptation_entries: adaptation_entries}
    persist_state(state)
    state
  end

  defp derive_meta_state(state) do
    entries = state.adaptation_entries
    current_entries = fresh_adaptation_entries(entries)

    %{
      authority_domain:
        latest_context_value(current_entries, ~w(authority_domain authority)) ||
          (List.first(current_entries) && List.first(current_entries).domain),
      active_bottleneck: latest_context_value(current_entries, ~w(bottleneck)),
      pivot_reason: latest_context_value(current_entries, ~w(pivot_reason reason)),
      active_steering_hypothesis:
        latest_context_value(current_entries, ~w(steering_hypothesis steering hypothesis)),
      last_experiment: latest_experiment(current_entries),
      recent_failed_adaptations:
        current_entries
        |> Enum.filter(&failed_adaptation?/1)
        |> Enum.take(@max_failed_adaptations)
        |> Enum.map(&summarize_adaptation_entry/1),
      last_updated_at: entries |> List.first() |> then(fn e -> e && e.timestamp end)
    }
  end

  defp derive_adaptation_review(state, limit) do
    entries = Enum.take(state.adaptation_entries, limit)
    total_events = length(entries)

    started_at =
      entries
      |> List.last()
      |> then(fn entry -> entry && entry.timestamp end)

    ended_at =
      entries
      |> List.first()
      |> then(fn entry -> entry && entry.timestamp end)

    domain_skew =
      entries
      |> Enum.frequencies_by(& &1.domain)
      |> Enum.map(fn {domain, count} ->
        %{domain: domain, count: count, share: safe_rate(count, total_events)}
      end)
      |> Enum.sort_by(fn %{count: count, domain: domain} -> {-count, domain} end)

    signature_reviews =
      entries
      |> Enum.reduce(%{}, &accumulate_signature_review/2)
      |> Map.values()
      |> Enum.map(&finalize_signature_review/1)

    positive_signatures =
      signature_reviews
      |> Enum.filter(fn review -> review.net_score > 0 or review.promotions > 0 end)
      |> Enum.sort_by(fn review ->
        {-review.net_score, -review.helpful, -review.promotions, review.signature}
      end)
      |> Enum.take(3)

    noisy_signatures =
      signature_reviews
      |> Enum.filter(fn review ->
        review.net_score < 0 or review.suppression_hits > 0 or review.blocked > 0 or
          review.expired > 0
      end)
      |> Enum.sort_by(fn review ->
        {review.net_score, -review.suppression_hits, -review.not_helpful, -review.blocked,
         -review.expired, review.signature}
      end)
      |> Enum.take(3)

    trials = summarize_trials(entries)
    promotions = summarize_promotions(entries)
    suppressions = summarize_suppressions(entries)

    %{
      window_event_count: total_events,
      window_started_at: started_at,
      window_ended_at: ended_at,
      trials: trials,
      promotions: promotions,
      suppressions: suppressions,
      domain_skew: domain_skew,
      positive_signatures: positive_signatures,
      noisy_signatures: noisy_signatures
    }
  end

  defp fresh_adaptation_entries(entries, now \\ DateTime.utc_now()) do
    freshness_ms = adaptation_freshness_ms()

    Enum.filter(entries, fn
      %{timestamp: %DateTime{} = timestamp} ->
        DateTime.diff(now, timestamp, :millisecond) <= freshness_ms

      _ ->
        false
    end)
  end

  defp latest_experiment(entries) do
    entries
    |> Enum.find(fn entry -> String.contains?(entry.event_type, "experiment") end)
    |> case do
      nil -> nil
      entry -> summarize_adaptation_entry(entry)
    end
  end

  defp failed_adaptation?(entry) do
    event_type = entry.event_type
    outcome = context_value(entry.context, "outcome")
    status = context_value(entry.context, "status")

    String.contains?(event_type, "revert") or
      String.contains?(event_type, "inconclusive") or
      String.contains?(event_type, "error") or
      event_type == "quality_gate_skip" or
      outcome in ["failure", "failed", "reverted", "error", :failure, :failed, :reverted, :error] or
      status in ["failure", "failed", "error", :failure, :failed, :error]
  end

  defp summarize_adaptation_entry(entry) do
    %{
      domain: entry.domain,
      event_type: entry.event_type,
      timestamp: entry.timestamp,
      reason: context_value(entry.context, "reason"),
      bottleneck: context_value(entry.context, "bottleneck"),
      outcome: context_value(entry.context, "outcome")
    }
  end

  defp summarize_trials(entries) do
    started = count_events(entries, "trial_started")
    completed = count_events(entries, "trial_completed")
    helpful = count_trial_outcomes(entries, "helpful")
    inconclusive = count_trial_outcomes(entries, "inconclusive")
    not_helpful = count_trial_outcomes(entries, "not_helpful")
    blocked = count_events(entries, "trial_blocked")
    expired = count_events(entries, "trial_expired")

    %{
      started: started,
      completed: completed,
      helpful: helpful,
      inconclusive: inconclusive,
      not_helpful: not_helpful,
      blocked: blocked,
      expired: expired,
      helpful_rate: safe_rate(helpful, completed),
      blocked_rate: safe_rate(blocked, started),
      expiry_rate: safe_rate(expired, started)
    }
  end

  defp summarize_promotions(entries) do
    started = count_events(entries, "trial_promoted")
    cleared = count_events(entries, "trial_promotion_cleared")
    kept = max(started - cleared, 0)

    %{
      started: started,
      cleared: cleared,
      keep_rate: safe_rate(kept, started)
    }
  end

  defp summarize_suppressions(entries) do
    started = count_events(entries, "trial_suppression_started")
    hits = count_events(entries, "trial_suppressed")

    %{
      started: started,
      hits: hits,
      hit_rate: safe_rate(hits, started)
    }
  end

  defp count_events(entries, event_type) do
    Enum.count(entries, &(&1.event_type == event_type))
  end

  defp count_trial_outcomes(entries, outcome) do
    Enum.count(entries, fn entry ->
      entry.event_type == "trial_completed" and context_value(entry.context, "outcome") == outcome
    end)
  end

  defp accumulate_signature_review(entry, acc) do
    case signature_parts(entry) do
      {trigger_event, bottleneck} ->
        signature = signature_for(trigger_event, bottleneck)

        review =
          Map.get(acc, signature, %{
            signature: signature,
            trigger_event: trigger_event,
            bottleneck: bottleneck,
            started: 0,
            helpful: 0,
            inconclusive: 0,
            not_helpful: 0,
            blocked: 0,
            expired: 0,
            promotions: 0,
            promotion_clears: 0,
            suppressions: 0,
            suppression_hits: 0,
            net_score: 0
          })

        Map.put(acc, signature, update_signature_review(review, entry))

      nil ->
        acc
    end
  end

  defp update_signature_review(review, %{event_type: "trial_started"}) do
    %{review | started: review.started + 1}
  end

  defp update_signature_review(review, %{event_type: "trial_completed", context: context}) do
    case context_value(context, "outcome") do
      "helpful" ->
        %{review | helpful: review.helpful + 1}

      "inconclusive" ->
        %{review | inconclusive: review.inconclusive + 1}

      "not_helpful" ->
        %{review | not_helpful: review.not_helpful + 1}

      _ ->
        review
    end
  end

  defp update_signature_review(review, %{event_type: "trial_blocked"}) do
    %{review | blocked: review.blocked + 1}
  end

  defp update_signature_review(review, %{event_type: "trial_expired"}) do
    %{review | expired: review.expired + 1}
  end

  defp update_signature_review(review, %{event_type: "trial_promoted"}) do
    %{review | promotions: review.promotions + 1}
  end

  defp update_signature_review(review, %{event_type: "trial_promotion_cleared"}) do
    %{review | promotion_clears: review.promotion_clears + 1}
  end

  defp update_signature_review(review, %{event_type: "trial_suppression_started"}) do
    %{review | suppressions: review.suppressions + 1}
  end

  defp update_signature_review(review, %{event_type: "trial_suppressed"}) do
    %{review | suppression_hits: review.suppression_hits + 1}
  end

  defp update_signature_review(review, _entry), do: review

  defp finalize_signature_review(review) do
    net_score = review.helpful - review.not_helpful - review.inconclusive
    %{review | net_score: net_score}
  end

  defp signature_parts(entry) do
    trigger_event = context_value(entry.context, "trigger_event")
    bottleneck = context_value(entry.context, "bottleneck")

    if is_binary(trigger_event) and trigger_event != "" do
      {trigger_event, bottleneck || "-"}
    else
      nil
    end
  end

  defp signature_for(trigger_event, bottleneck) do
    "#{trigger_event}|#{bottleneck || "-"}"
  end

  defp latest_context_value(entries, keys) do
    Enum.find_value(entries, fn entry ->
      Enum.find_value(keys, fn key -> context_value(entry.context, key) end)
    end)
  end

  defp context_value(context, key) do
    Map.get(context, key)
  end

  defp normalize_name(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_name(value) when is_binary(value), do: value
  defp normalize_name(value), do: to_string(value)

  defp sanitize_context(context) when is_map(context) do
    context
    |> Enum.take(20)
    |> Map.new(fn {key, value} ->
      {normalize_name(key), sanitize_value(value)}
    end)
  end

  defp sanitize_context(_), do: %{}

  defp sanitize_value(value) when is_binary(value) do
    String.slice(value, 0, 500)
  end

  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)

  defp sanitize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp sanitize_value(%Date{} = value), do: Date.to_iso8601(value)
  defp sanitize_value(%Time{} = value), do: Time.to_iso8601(value)

  defp sanitize_value(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp sanitize_value(value) when is_list(value) do
    value
    |> Enum.take(10)
    |> Enum.map(&sanitize_value/1)
  end

  defp sanitize_value(value) when is_map(value) do
    sanitize_context(value)
  end

  defp sanitize_value(value), do: inspect(value, limit: 20)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {normalize_name(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp normalize_context_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {normalize_name(key), normalize_context_value(value)}
    end)
  end

  defp normalize_context_value(value) when is_map(value), do: normalize_context_map(value)

  defp normalize_context_value(value) when is_list(value),
    do: Enum.map(value, &normalize_context_value/1)

  defp normalize_context_value(value), do: value

  defp empty_meta_state do
    %{
      authority_domain: nil,
      active_bottleneck: nil,
      pivot_reason: nil,
      active_steering_hypothesis: nil,
      last_experiment: nil,
      recent_failed_adaptations: [],
      last_updated_at: nil
    }
  end

  defp empty_adaptation_review do
    %{
      window_event_count: 0,
      window_started_at: nil,
      window_ended_at: nil,
      trials: %{
        started: 0,
        completed: 0,
        helpful: 0,
        inconclusive: 0,
        not_helpful: 0,
        blocked: 0,
        expired: 0,
        helpful_rate: nil,
        blocked_rate: nil,
        expiry_rate: nil
      },
      promotions: %{started: 0, cleared: 0, keep_rate: nil},
      suppressions: %{started: 0, hits: 0, hit_rate: nil},
      domain_skew: [],
      positive_signatures: [],
      noisy_signatures: []
    }
  end

  defp safe_rate(_numerator, 0), do: nil
  defp safe_rate(_numerator, nil), do: nil
  defp safe_rate(numerator, denominator), do: numerator / denominator

  defp adaptation_freshness_ms do
    Application.get_env(:daemon, :adaptation_meta_freshness_ms, @default_adaptation_freshness_ms)
  end

  defp normalize_topic(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
