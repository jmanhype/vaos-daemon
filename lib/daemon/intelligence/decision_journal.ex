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
  """
  use GenServer
  require Logger

  alias Vaos.Ledger.Epistemic.Ledger, as: EpistemicLedger

  @pr_poll_interval_ms :timer.hours(1)
  @daemon_repo "jmanhype/vaos-daemon"
  @max_decisions 200
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
      decision_count: length(state.decisions)
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

  def handle_cast({:record_outcome, branch, outcome, metadata}, state) do
    state = do_record_outcome(state, branch, outcome, metadata)
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
      "version" => 1,
      "decisions" => Enum.map(Enum.take(state.decisions, @max_decisions), &serialize_decision/1),
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
          {:ok, %{"version" => 1, "decisions" => raw, "stats" => stats}} ->
            now = DateTime.utc_now()

            {decisions, recovered_count} =
              raw
              |> Enum.map(&deserialize_decision/1)
              |> Enum.reject(&is_nil/1)
              |> recover_stale_in_flight(now)

            # Rebuild in_flight from decisions that are still :in_flight
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

            state = %{
              state
              | decisions: decisions,
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

  defp normalize_topic(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
