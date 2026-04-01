defmodule Daemon.Agent.WorkDirector do
  @moduledoc """
  Autonomous work loop that continuously picks tasks, dispatches them via
  Orchestrator PACT, ships draft PRs, and learns from merge/reject signals.

  Unifies five work sources under Thompson Sampling:
  - VISION.md strategic goals
  - GitHub Issues
  - Investigation findings
  - Fitness function violations
  - Manual submissions

  Coexists with InsightActuator (insight/ branches) and ConvergenceEngine
  (convergence/ branches). WorkDirector uses workdir/ branches.
  """
  use GenServer
  require Logger

  alias Daemon.Agent.WorkDirector.Backlog
  alias Daemon.Agent.WorkDirector.Backlog.WorkItem
  alias Daemon.Agent.WorkDirector.DispatchIntelligence
  alias Daemon.Agent.WorkDirector.DispatchJudgment
  alias Daemon.Agent.WorkDirector.Pipeline
  alias Daemon.Agent.WorkDirector.Source
  alias Daemon.Agent.Tasks
  alias Daemon.Agent.Debate
  alias Daemon.Intelligence.DecisionJournal
  alias Daemon.Vault
  alias Daemon.Agent.SkillEvolution

  @pr_poll_ms :timer.hours(1)
  @max_dispatches_per_day 24
  @max_completed_prs 50
  @daemon_repo "jmanhype/vaos-daemon"

  # -- Feature Flags (runtime config via Application.get_env(:daemon, :work_director_flags, %{})) --

  # Stage 3.5: Post-Dispatch Learning
  @enable_vault_remember true
  @enable_knowledge_remember true
  @enable_skill_evolution true

  # -- Pre-dispatch gates --
  @enable_risk_assessment true         # Pre-dispatch: score risk, force review on medium, block high
  @enable_risk_approval_gate true      # Pre-dispatch: route high-risk to Governance.Approvals
  @enable_strategic_rejection true     # Pre-dispatch: refuse tasks that violate architectural invariants
  @enable_strategic_debate true        # Pre-dispatch: LLM debate for borderline strategic rejections


  # -- Pre-dispatch judgment (Phase 2) --
  @enable_already_solved_check true     # Gate: skip tasks already solved by existing code or merged PRs
  @enable_pr_conflict_awareness true    # Gate: detect file conflicts with open PRs, inject awareness
  @enable_dispatch_confidence true      # Gate: aggregate confidence score, hold back when low
  @enable_task_decomposition true       # Gate: split broad low-confidence tasks into sub-items

  # Confidence/decomposition constants live in DispatchJudgment module

  @protected_path_patterns [
    "^lib/daemon/application\\.ex$",
    "^lib/daemon/supervisors/",
    "^lib/daemon/security/",
    "^lib/daemon/agent/loop\\.ex$",
    "^config/runtime\\.exs$",
    "^mix\\.exs$",
    "^mix\\.lock$"
  ]

  @source_modules [
    Source.Vision,
    Source.Issues,
    Source.Fitness
  ]

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get current stats: backlog size, dispatch counts, arm means, circuit breaker status."
  def stats do
    try do
      GenServer.call(__MODULE__, :stats)
    rescue
      _ -> %{status: :not_running}
    catch
      :exit, _ -> %{status: :not_running}
    end
  end

  @doc "Enable the work loop."
  def enable do
    try do
      GenServer.cast(__MODULE__, :enable)
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  @doc "Disable the work loop."
  def disable do
    try do
      GenServer.cast(__MODULE__, :disable)
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  @doc "Check if WorkDirector is currently dispatching (has an active agent on the repo)."
  @spec dispatching?() :: boolean()
  def dispatching? do
    try do
      GenServer.call(__MODULE__, :dispatching?, 2_000)
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  @doc "Submit a manual work item."
  def submit(title, description, priority \\ 0.5) do
    try do
      GenServer.cast(__MODULE__, {:submit, title, description, priority})
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  @doc "Force immediate backlog refresh and dispatch attempt."
  def force_cycle do
    try do
      GenServer.cast(__MODULE__, :force_cycle)
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  @doc "List all backlog items (debugging)."
  def backlog do
    try do
      GenServer.call(__MODULE__, :backlog)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end


  @doc "Run one refresh-and-select cycle (called by Scheduler cron job)."
  def refresh_and_select do
    try do
      GenServer.call(__MODULE__, :refresh_and_select, 60_000)
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)

    state = %{
      enabled: enabled,
      backlog: %{},
      arms: default_arms(),
      current_dispatch: nil,
      completed_prs: [],
      dispatches_today: 0,
      last_day_reset: Date.utc_today(),
      consecutive_failures: 0,
      total_dispatches: 0,
      total_merged: 0,
      total_rejected: 0,
      investigation_buffer: nil,
      manual_buffer: nil,
      investigation_ref: nil,
      blocked_regexes: Enum.map(@protected_path_patterns, &Regex.compile!/1)
    }

    # Load persisted arms (survive restarts)
    state = load_persisted_arms(state)

    # Load persisted backlog
    persisted =
      try do
        Backlog.load()
      rescue
        e ->
          Logger.warning("[WorkDirector] Failed to load backlog: #{Exception.message(e)}")
          %{}
      end

    state = %{state | backlog: persisted}

    # Initialize buffers and event subscriptions (one-time setup)
    if enabled do
      {inv_buffer, manual_buffer, investigation_ref} = initialize_buffers_and_events()
      state = %{state |
        investigation_buffer: inv_buffer,
        manual_buffer: manual_buffer,
        investigation_ref: investigation_ref
      }

      # Start PR outcome polling timer (separate from scheduler cron)
      schedule_pr_poll()

      Logger.info("[WorkDirector] Started (enabled=true, arms=#{inspect(Map.keys(state.arms))}, backlog=#{map_size(state.backlog)})")
      {:ok, state}
    else
      Logger.info("[WorkDirector] Started (enabled=false)")
      {:ok, state}
    end
  end

  defp default_arms do
    %{
      vision: %{alpha: 1.0, beta: 1.0},
      issues: %{alpha: 1.0, beta: 1.0},
      investigation: %{alpha: 1.0, beta: 1.0},
      fitness: %{alpha: 1.0, beta: 1.0},
      manual: %{alpha: 2.0, beta: 1.0}
    }
  end


  @impl true
  def handle_info({:dispatch_complete, ref, task_id, result}, %{current_dispatch: %{ref: dispatch_ref}} = state)
      when ref == dispatch_ref do
    dispatch = state.current_dispatch
    state = %{state | current_dispatch: nil}

    # Mark task as completed or failed in the queue
    case result do
      {:ok, _output, branch} ->
        Tasks.complete_queued(task_id, %{branch: branch, status: :success})
      {:error, _reason} ->
        Tasks.fail_queued(task_id, result)
    end

    state =
      case result do
        {:ok, _output, branch} ->
          case verify_safety(branch) do
            :safe ->
              Logger.info("[WorkDirector] Dispatch completed: #{dispatch.title} (branch=#{branch})")
              DecisionJournal.record_outcome(branch, :success, %{title: dispatch.title})

              state
              |> update_backlog_completed(dispatch.content_hash, {:ok, branch})
              |> reward_arm(dispatch.source, 0.8)
              |> add_completed_pr(branch, dispatch.source, dispatch.content_hash)
              |> Map.put(:consecutive_failures, 0)
              |> Map.update!(:total_dispatches, &(&1 + 1))

            :unsafe ->
              Logger.warning("[WorkDirector] Safety violation in #{branch}, deleting branch")
              delete_branch(branch)
              DecisionJournal.record_outcome(branch, :failure, %{reason: :safety_violation})

              state
              |> update_backlog_completed(dispatch.content_hash, {:safety_violation, branch})
              |> reward_arm(dispatch.source, 0.0)
              |> Map.put(:consecutive_failures, 0)
          end

        {:error, reason} ->
          failure_class = classify_failure(reason)
          Logger.warning("[WorkDirector] Dispatch failed: #{failure_class} — #{inspect(reason)}")
          DecisionJournal.record_outcome(dispatch.branch, :failure, %{
            reason: inspect(reason),
            failure_class: failure_class
          })

          # Reward based on failure class — widened spread for clear Thompson signal
          reward = failure_class_reward(failure_class)
          failures = state.consecutive_failures + 1

          state
          |> update_backlog_failed(dispatch.content_hash, %{class: failure_class, reason: reason})
          |> reward_arm(dispatch.source, reward)
          |> Map.put(:consecutive_failures, failures)
      end

    # Stage 3.5: Post-dispatch — remember outcome, store knowledge, evolve skills
    post_dispatch_learn(dispatch, result)

    # Persist and continue the loop (throttled)
    Backlog.persist(state.backlog)

    {:noreply, state}
  end

  # Handle DOWN from spawned dispatch process
  def handle_info({:DOWN, _monitor_ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _monitor_ref, :process, _pid, reason}, state) when state.current_dispatch != nil do
    Logger.error("[WorkDirector] Dispatch process crashed: #{inspect(reason)}")
    dispatch = state.current_dispatch
    failures = state.consecutive_failures + 1

    state =
      state
      |> Map.put(:current_dispatch, nil)
      |> update_backlog_failed(dispatch.content_hash, %{class: :process_crash, reason: reason})
      |> Map.put(:consecutive_failures, failures)

    Backlog.persist(state.backlog)

    {:noreply, state}
  end

  def handle_info({:DOWN, _monitor_ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Handle PR outcome from Decision Journal (unified polling)
  def handle_info({:journal_pr_outcome, branch, reward}, state) do
    match = Enum.find(state.completed_prs, fn cp -> cp.branch == branch end)

    if match do
      Logger.info("[WorkDirector] Journal PR outcome for #{branch}: reward=#{reward}")
      state = reward_arm(state, match.source, reward)
      state = remove_completed_pr(state, branch)

      state = if reward >= 0.5 do
        Map.update!(state, :total_merged, &(&1 + 1))
      else
        Map.update!(state, :total_rejected, &(&1 + 1))
      end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll_pr_outcomes, state) do
    state = poll_pr_outcomes(state)
    schedule_pr_poll()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[WorkDirector] Unexpected message: #{inspect(msg, limit: 200)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      status: if(state.enabled, do: :running, else: :disabled),
      backlog_size: map_size(state.backlog),
      pending_count: state.backlog |> Map.values() |> Enum.count(&(&1.status == :pending)),
      dispatches_today: state.dispatches_today,
      current_dispatch: if(state.current_dispatch, do: state.current_dispatch.title, else: nil),
      arms: Enum.map(state.arms, fn {source, %{alpha: a, beta: b}} ->
        {source, %{alpha: a, beta: b, mean: Float.round(a / (a + b), 3)}}
      end) |> Map.new(),
      consecutive_failures: state.consecutive_failures,
      total_dispatches: state.total_dispatches,
      total_merged: state.total_merged,
      total_rejected: state.total_rejected,
      completed_prs: length(state.completed_prs)
    }

    {:reply, stats, state}
  end

  def handle_call(:dispatching?, _from, state) do
    {:reply, state.current_dispatch != nil, state}
  end

  def handle_call(:backlog, _from, state) do
    items =
      state.backlog
      |> Map.values()
      |> Enum.sort_by(& &1.base_priority, :desc)
      |> Enum.map(fn item ->
        %{
          title: item.title,
          source: item.source,
          status: item.status,
          priority: item.base_priority,
          attempts: item.attempt_count,
          branch: item.pr_branch
        }
      end)

    {:reply, items, state}
  end

  def handle_call(:refresh_and_select, _from, state) do
    Logger.debug("[WorkDirector] refresh_and_select cycle starting")

    # Reset daily counter if needed
    state = maybe_reset_daily_counter(state)

    # Refresh backlog from all sources
    state = refresh_backlog(state)

    # Try to dispatch if eligible
    state =
      if state.current_dispatch == nil and state.enabled do
        try_dispatch_one(state)
      else
        state
      end

    # Persist backlog state
    Backlog.persist(state.backlog)

    {:reply, {:ok, %{
      backlog_size: map_size(state.backlog),
      dispatched: state.current_dispatch != nil
    }}, state}
  end

  @impl true
  def handle_cast(:enable, state) do
    Logger.info("[WorkDirector] Enabled")
    state = %{state | enabled: true}
    {:noreply, state}
  end

  def handle_cast(:disable, state) do
    Logger.info("[WorkDirector] Disabled")
    {:noreply, %{state | enabled: false}}
  end

  def handle_cast({:submit, title, description, priority}, state) do
    if state.manual_buffer do
      Source.Manual.submit(state.manual_buffer, title, description, priority)
      Logger.info("[WorkDirector] Manual task submitted: #{title}")
    end

    {:noreply, state}
  end

  def handle_cast(:force_cycle, state) do
    Logger.info("[WorkDirector] Force cycle triggered")
    state = refresh_backlog(state)
    {:noreply, state}
  end

  # -- Internal --

  defp get_flag(flag_name, default) do
    Application.get_env(:daemon, :work_director_flags, %{})
    |> Map.get(flag_name, default)
  end

  defp initialize_buffers_and_events do
    # Start buffers for event-driven sources
    {:ok, inv_buffer} = Source.Investigation.start_buffer()
    {:ok, manual_buffer} = Source.Manual.start_buffer()
    Logger.debug("[WorkDirector] Buffers started")

    # Subscribe to investigation_complete events (async — don't block init)
    investigation_ref =
      try do
        handler = fn event ->
          data = Map.get(event, :data, Map.get(event, "data", %{}))
          Source.Investigation.push(inv_buffer, data)
        end

        # Use a timeout to avoid blocking if Bus is busy
        task = Task.async(fn -> Daemon.Events.Bus.register_handler(:investigation_complete, handler) end)
        case Task.yield(task, 5_000) || Task.shutdown(task) do
          {:ok, ref} -> ref
          _ ->
            Logger.warning("[WorkDirector] Bus subscription timed out — skipping")
            nil
        end
      rescue
        e ->
          Logger.warning("[WorkDirector] Failed to subscribe to events: #{Exception.message(e)}")
          nil
      catch
        :exit, reason ->
          Logger.warning("[WorkDirector] Failed to subscribe to events: #{inspect(reason)}")
          nil
      end

    Logger.debug("[WorkDirector] Event subscription done (ref=#{inspect(investigation_ref)})")

    {inv_buffer, manual_buffer, investigation_ref}
  end

  defp try_dispatch_one(state) do
    # Check dispatch eligibility
    cond do
      not state.enabled ->
        state

      state.dispatches_today >= @max_dispatches_per_day ->
        Logger.debug("[WorkDirector] Daily dispatch cap reached (#{state.dispatches_today}/#{@max_dispatches_per_day})")
        state

      true ->
        # Try to pick and dispatch one item (gates + queue)
        case Backlog.pick_next(state.backlog, state.arms) do
          :empty ->
            state

          {:ok, item} ->
            dispatch_item(state, item)
        end
    end
  end

  defp refresh_backlog(state) do
    Logger.debug("[WorkDirector] Refreshing backlog from #{length(@source_modules)} static sources...")

    # Fetch each source independently with timeout
    static_items =
      Enum.flat_map(@source_modules, fn mod ->
        source_name = mod |> Module.split() |> List.last()
        Logger.debug("[WorkDirector] Fetching from #{source_name}...")

        try do
          task = Task.async(fn -> mod.fetch() end)
          case Task.yield(task, 15_000) || Task.shutdown(task) do
            {:ok, {:ok, items}} ->
              Logger.debug("[WorkDirector] #{source_name}: #{length(items)} items")
              items

            {:ok, {:error, reason}} ->
              Logger.warning("[WorkDirector] #{source_name} error: #{inspect(reason)}")
              []

            nil ->
              Logger.warning("[WorkDirector] #{source_name} timed out (15s)")
              []
          end
        rescue
          e ->
            Logger.warning("[WorkDirector] #{source_name} crashed: #{Exception.message(e)}")
            []
        catch
          :exit, reason ->
            Logger.warning("[WorkDirector] #{source_name} exit: #{inspect(reason)}")
            []
        end
      end)

    Logger.debug("[WorkDirector] Static sources returned #{length(static_items)} items")

    # Fetch from buffer-based sources
    inv_items =
      if state.investigation_buffer do
        case Source.Investigation.fetch(state.investigation_buffer) do
          {:ok, items} -> items
          _ -> []
        end
      else
        []
      end

    manual_items =
      if state.manual_buffer do
        case Source.Manual.fetch(state.manual_buffer) do
          {:ok, items} -> items
          _ -> []
        end
      else
        []
      end

    all_items = static_items ++ inv_items ++ manual_items
    backlog = Backlog.merge(state.backlog, all_items) |> Backlog.prune_stale()

    pending = backlog |> Map.values() |> Enum.count(&(&1.status == :pending))
    Logger.info("[WorkDirector] Backlog refreshed: #{map_size(backlog)} items (#{pending} pending, #{length(all_items)} fetched)")

    %{state | backlog: backlog}
  end

  defp dispatch_item(state, %WorkItem{} = item) do
    branch = branch_name(item)

    # Check with Decision Journal for conflicts
    case DecisionJournal.propose(:work_director, :create_pr, %{
      topic: item.title,
      branch: branch,
      source: item.source,
      priority: item.base_priority
    }) do
      {:conflict, reason} ->
        Logger.info("[WorkDirector] Journal conflict for '#{item.title}': #{reason}")
        {:conflict, state}

      :approved ->
        repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

        # Gate 1: Strategic rejection (rule-based, zero LLM cost)
        case maybe_reject_strategically(item) do
          {:rejected, reason} ->
            Logger.info("[WorkDirector] Strategic rejection: '#{item.title}' — #{reason}")
            DecisionJournal.record_outcome(branch, :failure, %{reason: "strategic_rejection", detail: reason})
            {:conflict, state}

          :proceed ->
            # Compute enrichment once (cached in process dict for all downstream uses)
            enrichment = get_or_compute_enrichment(item, repo_path)

            # Gate 2: Already-solved check (Phase 2)
            case maybe_check_already_solved(item, enrichment, repo_path) do
              {:already_solved, reason} ->
                Logger.info("[WorkDirector] Already solved: '#{item.title}' — #{reason}")
                DecisionJournal.record_outcome(branch, :failure, %{reason: "already_solved", detail: reason})
                backlog = Backlog.mark_completed(state.backlog, item.content_hash, {:already_solved, reason})
                {:conflict, %{state | backlog: backlog}}

              :not_solved ->
                # Gate 3: Risk assessment (pattern matching + optional DispatchIntelligence)
                risk = assess_risk(item, repo_path)

                # Gate 4: PR conflict awareness (Phase 2)
                pr_conflicts = maybe_check_pr_conflicts(item, enrichment, repo_path)

                # Gate 5: Confidence routing (Phase 2 — subsumes old maybe_gate_on_risk)
                case maybe_route_by_confidence(item, enrichment, risk, pr_conflicts, state) do
                  {:proceed, confidence} ->
                    Logger.info("[WorkDirector] Confidence #{confidence.score} (#{confidence.level}) — dispatching '#{item.title}'")
                    do_dispatch_item(state, item, branch)

                  {:proceed_with_review, confidence} ->
                    Logger.info("[WorkDirector] Confidence #{confidence.score} (medium) — dispatching with review for '#{item.title}'")
                    judgment_ctx = %{
                      confidence: confidence,
                      pr_conflicts: pr_conflicts,
                      force_review: true
                    }
                    do_dispatch_item(state, item, branch, judgment_ctx)

                  {:decompose, confidence} ->
                    Logger.info("[WorkDirector] Confidence #{confidence.score} (low) — decomposing '#{item.title}'")
                    maybe_decompose_task(state, item, enrichment, repo_path, branch, confidence)

                  {:skip, confidence} ->
                    Logger.info("[WorkDirector] Confidence #{confidence.score} (low) — skipping '#{item.title}'")
                    DecisionJournal.record_outcome(branch, :failure, %{
                      reason: "low_confidence", score: confidence.score
                    })
                    {:conflict, state}
                end
            end
        end
    end
  end

  # -- Risk assessment thresholds --
  @risk_high_threshold 7
  @risk_medium_threshold 4
  @high_risk_keywords ~w(refactor rewrite replace migrate supervisor application security genserver)

  @stop_words ~w(the a an is are was were be been being have has had do does did will would shall should may might must can could)

  # -- Pre-dispatch Gate: Strategic Rejection --

  defp maybe_reject_strategically(item) do
    if @enable_strategic_rejection do
      try do
        text = String.downcase("#{item.title} #{item.description}")
        issues = []

        # Check 1: Architectural invariant violations
        invariants = Source.Vision.load_invariants()
        issues = issues ++ check_invariant_violations(text, invariants)

        # Check 2: Scope too broad
        issues = issues ++ check_scope_breadth(text)

        # Check 3: Duplicates recently completed work
        issues = issues ++ check_vault_duplicate(item)

        cond do
          issues == [] -> :proceed
          get_flag(:enable_strategic_debate, @enable_strategic_debate) ->
            evaluate_with_debate(item, issues, invariants)
          true -> {:rejected, Enum.join(issues, "; ")}
        end
      rescue
        _ -> :proceed
      catch
        :exit, _ -> :proceed
      end
    else
      :proceed
    end
  end

  defp check_invariant_violations(text, invariants) do
    invariants
    |> Enum.filter(fn inv -> String.contains?(String.downcase(inv), "never") end)
    |> Enum.flat_map(fn inv ->
      # Extract meaningful words (>3 chars, excluding stop words) from the invariant
      forbidden_terms =
        inv
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9\s]/, " ")
        |> String.split()
        |> Enum.reject(&(&1 in @stop_words))
        |> Enum.filter(&(String.length(&1) > 3))
        |> Enum.reject(&(&1 == "never"))

      matches = Enum.filter(forbidden_terms, &String.contains?(text, &1))

      if length(matches) >= 2 do
        ["Violates invariant: #{inv} (matched: #{Enum.join(matches, ", ")})"]
      else
        []
      end
    end)
  end

  defp check_scope_breadth(text) do
    broad_keywords = ~w(all every entire whole rewrite)
    hits = Enum.count(broad_keywords, &String.contains?(text, &1))

    if hits >= 2 do
      ["Scope too broad — #{hits} broad-scope keywords detected"]
    else
      []
    end
  end

  defp check_vault_duplicate(item) do
    try do
      recalls = Vault.recall(item.title, limit: 3)

      duplicates =
        Enum.filter(recalls, fn {_cat, path, score} ->
          score > 0.8 and
            case File.read(path) do
              {:ok, content} -> String.contains?(content, "Successful Implementation")
              _ -> false
            end
        end)

      if duplicates != [] do
        ["Potential duplicate of recently completed work (#{length(duplicates)} similar successes found)"]
      else
        []
      end
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp evaluate_with_debate(item, issues, invariants) do
    try do
      concerns = Enum.join(issues, "\n- ")
      inv_text = if invariants != [], do: "\n\nArchitectural Invariants:\n" <> Enum.map_join(invariants, "\n", &("- #{&1}")), else: ""

      prompt = """
      A WorkDirector dispatch is being considered. Evaluate whether it should proceed or be rejected.

      Task: #{item.title}
      Description: #{item.description}

      Concerns raised by rule-based checks:
      - #{concerns}
      #{inv_text}

      Debate this task. End your response with exactly one of:
      VERDICT: PROCEED
      VERDICT: REJECT
      """

      case Debate.run(prompt, perspectives: [:advocate, :critic]) do
        {:ok, %{synthesis: synthesis}} ->
          if String.contains?(synthesis, "VERDICT: REJECT") do
            {:rejected, "Debate rejected: #{String.slice(synthesis, 0, 200)}"}
          else
            :proceed
          end

        _ ->
          # Debate failed — fall back to rule-based rejection
          {:rejected, Enum.join(issues, "; ")}
      end
    rescue
      _ -> {:rejected, Enum.join(issues, "; ")}
    catch
      :exit, _ -> {:rejected, Enum.join(issues, "; ")}
    end
  end

  # -- Pre-dispatch Gate: Risk Assessment --

  defp assess_risk(item, repo_path) do
    if @enable_risk_assessment do
      try do
        # Factor 1: Title keyword hits (0-3)
        title_lower = String.downcase(item.title)
        keyword_hits = Enum.count(@high_risk_keywords, &String.contains?(title_lower, &1))
        keyword_score = min(keyword_hits, 3)

        # Factor 2: Core path proximity (0-3) — uses DispatchIntelligence
        enrichment = get_or_compute_enrichment(item, repo_path)
        relevant_paths = enrichment |> Map.get(:relevant_files, []) |> Enum.map(& &1.path)

        core_score =
          relevant_paths
          |> Enum.count(fn path ->
            Enum.any?(@protected_path_patterns, fn pattern ->
              rel = Path.relative_to(path, repo_path)
              Regex.match?(Regex.compile!(pattern), rel)
            end)
          end)
          |> min(3)

        # Factor 3: Blast radius (0-2)
        file_count = length(relevant_paths)
        integration_count = enrichment |> Map.get(:integration_points, []) |> length()
        blast_score = cond do
          file_count + integration_count > 10 -> 2
          file_count + integration_count > 5 -> 1
          true -> 0
        end

        # Factor 4: Historical failures (0-2)
        failure_score =
          try do
            recalls = Vault.recall(item.title, limit: 5)
            failures = Enum.count(recalls, fn {_cat, path, _score} ->
              case File.read(path) do
                {:ok, content} -> String.contains?(content, "Failed") or String.contains?(content, "failure")
                _ -> false
              end
            end)
            min(failures, 2)
          rescue
            _ -> 0
          catch
            :exit, _ -> 0
          end

        score = keyword_score + core_score + blast_score + failure_score

        level = cond do
          score >= @risk_high_threshold -> :high
          score >= @risk_medium_threshold -> :medium
          true -> :low
        end

        Logger.info("[WorkDirector] Risk assessment for '#{item.title}': #{score}/10 (#{level}) — keywords=#{keyword_score}, core=#{core_score}, blast=#{blast_score}, failures=#{failure_score}")

        %{
          score: score,
          level: level,
          breakdown: %{
            keywords: keyword_score,
            core_proximity: core_score,
            blast_radius: blast_score,
            historical_failures: failure_score
          }
        }
      rescue
        e ->
          Logger.warning("[WorkDirector] Risk assessment crashed, defaulting to HIGH: #{Exception.message(e)}")
          %{score: 7, level: :high, breakdown: %{error: "assessment_crashed"}}
      catch
        :exit, reason ->
          Logger.warning("[WorkDirector] Risk assessment exit, defaulting to HIGH: #{inspect(reason)}")
          %{score: 7, level: :high, breakdown: %{error: "assessment_exit"}}
      end
    else
      %{score: 0, level: :low, breakdown: %{}}
    end
  end

  defp get_or_compute_enrichment(item, repo_path) do
    case Process.get(:dispatch_intelligence_cache) do
      nil ->
        case DispatchIntelligence.enrich(item.title, item.description || "", repo_path) do
          {:ok, result} ->
            Process.put(:dispatch_intelligence_cache, result)
            result

          _ ->
            %{}
        end

      cached ->
        cached
    end
  end

  defp maybe_gate_on_risk(%{level: :low}, _item), do: :proceed
  defp maybe_gate_on_risk(%{level: :medium} = risk, _item), do: {:force_review, risk}
  defp maybe_gate_on_risk(%{level: :high} = risk, item) do
    if @enable_risk_approval_gate do
      try do
        alias Daemon.Governance.Approvals

        case Approvals.create(%{
          type: "code_change",
          title: "High-risk: #{item.title}",
          description: "Risk #{risk.score}/10: #{inspect(risk.breakdown)}",
          requested_by: "work_director",
          context: risk.breakdown
        }) do
          {:ok, _} -> {:blocked, "Governance approval required (risk=#{risk.score}/10)"}
          _ -> {:force_review, risk}
        end
      rescue
        _ -> {:force_review, risk}
      catch
        :exit, _ -> {:force_review, risk}
      end
    else
      {:force_review, risk}
    end
  end
  defp maybe_gate_on_risk(_risk, _item), do: :proceed

  # -- Phase 2: Dispatch Judgment Wrappers --

  defp maybe_check_already_solved(item, enrichment, repo_path) do
    if @enable_already_solved_check do
      try do
        DispatchJudgment.check_already_solved(item, enrichment, repo_path)
      rescue
        _ -> :not_solved
      catch
        :exit, _ -> :not_solved
      end
    else
      :not_solved
    end
  end

  defp maybe_check_pr_conflicts(item, enrichment, repo_path) do
    if @enable_pr_conflict_awareness do
      try do
        DispatchJudgment.check_pr_conflicts(item, enrichment, repo_path)
      rescue
        _ -> %{open_pr_conflicts: [], hot_zones: [], conflict_score: 0.0}
      catch
        :exit, _ -> %{open_pr_conflicts: [], hot_zones: [], conflict_score: 0.0}
      end
    else
      %{open_pr_conflicts: [], hot_zones: [], conflict_score: 0.0}
    end
  end

  defp maybe_route_by_confidence(item, enrichment, risk, pr_conflicts, _state) do
    if @enable_dispatch_confidence do
      try do
        confidence = DispatchJudgment.compute_confidence(item, enrichment, risk, pr_conflicts)
        Logger.debug("[WorkDirector] Confidence breakdown: #{inspect(confidence.breakdown)}")
        {confidence.recommendation, confidence}
      rescue
        _ -> {:proceed, %{score: 0.6, level: :medium}}
      catch
        :exit, _ -> {:proceed, %{score: 0.6, level: :medium}}
      end
    else
      # Fall back to existing risk-based routing
      case maybe_gate_on_risk(risk, item) do
        :proceed -> {:proceed, %{score: 0.8, level: :high}}
        {:force_review, _} -> {:proceed_with_review, %{score: 0.5, level: :medium}}
        {:blocked, reason} -> {:skip, %{score: 0.1, level: :low, reason: reason}}
      end
    end
  end

  defp maybe_decompose_task(state, item, enrichment, repo_path, branch, confidence) do
    if @enable_task_decomposition do
      try do
        case DispatchJudgment.decompose(item, enrichment, repo_path) do
          {:ok, sub_items} ->
            Logger.info("[WorkDirector] Decomposed '#{item.title}' into #{length(sub_items)} sub-items")

            if state.manual_buffer do
              Enum.each(sub_items, fn sub ->
                Source.Manual.submit(state.manual_buffer, sub.title, sub.description, sub.base_priority)
              end)
            end

            backlog = Backlog.mark_completed(state.backlog, item.content_hash, {:decomposed, length(sub_items)})
            DecisionJournal.record_outcome(branch, :success, %{reason: "decomposed", count: length(sub_items)})
            {:conflict, %{state | backlog: backlog}}

          :cannot_decompose ->
            Logger.info("[WorkDirector] Cannot decompose '#{item.title}', skipping")
            DecisionJournal.record_outcome(branch, :failure, %{reason: "low_confidence_narrow"})
            {:conflict, state}
        end
      rescue
        _ -> {:conflict, state}
      catch
        :exit, _ -> {:conflict, state}
      end
    else
      DecisionJournal.record_outcome(branch, :failure, %{reason: "low_confidence", score: confidence.score})
      {:conflict, state}
    end
  end

  defp do_dispatch_item(state, item, branch, judgment_ctx \\ nil)

  defp do_dispatch_item(state, %WorkItem{} = item, branch, judgment_ctx) do
    session_id = "workdir-#{:erlang.unique_integer([:positive])}"

    Logger.info("[WorkDirector] Dispatching: #{item.title} (source=#{item.source}, priority=#{item.base_priority})")

    # Enqueue task to queue
    task_id = "workdir-#{item.content_hash}"
    payload = %{
      item: item,
      branch: branch,
      session_id: session_id,
      repo_path: Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))
    }

    case Tasks.enqueue_sync(task_id, "work_director", payload) do
      {:ok, _task} ->
        # Immediately lease it (we're the only dispatcher)
        case Tasks.lease("work_director", 60_000) do
          {:ok, leased_task} ->
            execute_queued_task_from_do_dispatch(state, item, branch, session_id, judgment_ctx, leased_task)

          :empty ->
            Logger.warning("[WorkDirector] Failed to lease immediately enqueued task")
            state
        end

      {:error, reason} ->
        Logger.error("[WorkDirector] Failed to enqueue task: #{inspect(reason)}")
        state
    end
  end

  defp execute_queued_task_from_do_dispatch(state, item, branch, session_id, judgment_ctx, task) do
    parent = self()
    ref = make_ref()
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    {_pid, _monitor_ref} =
      spawn_monitor(fn ->
        # Propagate judgment context into spawned process so Pipeline.run can read it
        if judgment_ctx, do: Process.put(:dispatch_judgment_context, judgment_ctx)

        result =
          try do
            Pipeline.run(item, branch, session_id, repo_path)
          rescue
            e -> {:error, {:exception, Exception.message(e)}}
          catch
            :exit, reason -> {:error, {:exit, reason}}
          end

        send(parent, {:dispatch_complete, ref, task.task_id, result})
      end)

    backlog = Backlog.mark_dispatched(state.backlog, item.content_hash, branch)

    try do
      Daemon.Events.Bus.emit(:work_dispatched, %{
        title: item.title,
        source: item.source,
        branch: branch,
        priority: item.base_priority
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    %{state |
      backlog: backlog,
      current_dispatch: %{
        ref: ref,
        task_id: task.task_id,
        content_hash: item.content_hash,
        source: item.source,
        title: item.title,
        branch: branch,
        started_at: DateTime.utc_now()
      },
      dispatches_today: state.dispatches_today + 1
    }
  end

  # -- Stage 3.5: Post-Dispatch Learning --

  defp post_dispatch_learn(dispatch, result) do
    # Vault: remember dispatch outcome
    if get_flag(:enable_vault_remember, @enable_vault_remember) do
      try do
        {category, content} =
          case result do
            {:ok, _output, branch} ->
              repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

              {diff_stat, _} =
                System.cmd("git", ["diff", "--stat", "main...#{branch}", "--", "*.ex", "*.exs"],
                  cd: repo_path, stderr_to_stdout: true)

              {diff_content, _} =
                System.cmd("git", ["diff", "main...#{branch}", "--", "*.ex", "*.exs"],
                  cd: repo_path, stderr_to_stdout: true)

              {:lesson, """
              ## Successful Implementation: #{dispatch.title}
              Source: #{dispatch.source} | Branch: #{branch}

              ### Files Changed
              #{String.slice(diff_stat, 0, 500)}

              ### Implementation Diff (exemplar)
              ```diff
              #{String.slice(diff_content, 0, 2500)}
              ```
              """}

            {:error, reason} ->
              fc = classify_failure(reason)

              {:lesson, """
              ## Failed Implementation: #{dispatch.title}
              Source: #{dispatch.source} | Class: #{fc}
              Error: #{inspect(reason) |> String.slice(0, 500)}

              Lesson: Avoid this approach for similar tasks.
              """}
          end

        Vault.remember(content, category, %{
          title: "workdir-#{String.slice(dispatch.title, 0, 40)}",
          session_id: "workdir-vault"
        })

        Logger.info("[WorkDirector] Stage 3.5: Vault remembered #{category} for '#{String.slice(dispatch.title, 0, 50)}'")
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    # Knowledge Store: assert dispatch outcome as triple
    if get_flag(:enable_knowledge_remember, @enable_knowledge_remember) do
      try do
        store = "osa_default"
        slug = String.slice(dispatch.title, 0, 60) |> String.replace(~r/[^a-zA-Z0-9]/, "_")
        outcome = if match?({:ok, _, _}, result), do: "success", else: "failure"

        Vaos.Knowledge.assert(store, {"workdir:#{slug}", "osa:dispatch_outcome", outcome})
        Vaos.Knowledge.assert(store, {"workdir:#{slug}", "osa:source", to_string(dispatch.source)})
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    # SkillEvolution: trigger evolution on failure
    if get_flag(:enable_skill_evolution, @enable_skill_evolution) do
      case result do
        {:error, reason} ->
          try do
            fc = classify_failure(reason)

            SkillEvolution.trigger_evolution("workdir-#{dispatch.title}", %{
              reason: inspect(fc),
              title: dispatch.title,
              source: dispatch.source,
              failure_class: fc
            })

            Logger.info("[WorkDirector] Stage 3.5: Triggered skill evolution for #{fc}")
          rescue
            _ -> :ok
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end
    end
  end

  # -- Failure Classification --

  defp classify_failure({:empty_branch, _}), do: :empty_branch
  defp classify_failure({:no_branch, _}), do: :no_branch_created
  defp classify_failure({:orchestrator_failed, _}), do: :orchestrator_error
  defp classify_failure({:timeout, _}), do: :timeout
  defp classify_failure({:compilation_unfixable, _}), do: :compilation_error
  defp classify_failure({:phantom_references, _}), do: :phantom_references
  defp classify_failure({:stub_detected, _}), do: :stub_detected
  defp classify_failure({:autofixer_exhausted, _}), do: :compilation_error
  defp classify_failure({:autofixer_error, _}), do: :compilation_error
  defp classify_failure({:commit_failed, _}), do: :commit_error
  defp classify_failure({:exception, msg}) when is_binary(msg) do
    cond do
      String.contains?(msg, "compile") -> :compilation_error
      String.contains?(msg, "test") -> :test_failure
      true -> :exception
    end
  end
  defp classify_failure({:exit, _}), do: :process_crash
  defp classify_failure(_), do: :unknown

  # Reward based on how far the dispatch got
  # -- Arm Persistence --

  @arms_dir Path.expand("~/.daemon/work_director")
  @arms_file Path.join(@arms_dir, "arms.json")

  defp persist_arms(state) do
    data = %{
      "version" => 1,
      "arms" => Map.new(state.arms, fn {source, arm} ->
        {to_string(source), %{"alpha" => arm.alpha, "beta" => arm.beta}}
      end),
      "stats" => %{
        "total_dispatches" => state.total_dispatches,
        "total_merged" => state.total_merged,
        "total_rejected" => state.total_rejected
      }
    }

    File.mkdir_p!(@arms_dir)
    File.write!(@arms_file, Jason.encode!(data, pretty: true))
  rescue
    e ->
      Logger.warning("[WorkDirector] Failed to persist arms: #{Exception.message(e)}")
  end

  defp load_persisted_arms(state) do
    case File.read(@arms_file) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"version" => 1, "arms" => raw_arms} = data} ->
            arms =
              Enum.reduce(raw_arms, state.arms, fn {source_str, arm_data}, acc ->
                try do
                  source = String.to_existing_atom(source_str)
                  alpha = arm_data["alpha"] || 1.0
                  beta = arm_data["beta"] || 1.0

                  if is_number(alpha) and is_number(beta) and alpha > 0 and beta > 0 do
                    Map.put(acc, source, %{alpha: alpha / 1.0, beta: beta / 1.0})
                  else
                    acc
                  end
                rescue
                  ArgumentError ->
                    Logger.warning("[WorkDirector] Skipping unknown arm source: #{source_str}")
                    acc
                end
              end)

            stats = Map.get(data, "stats", %{})

            %{state |
              arms: arms,
              total_dispatches: Map.get(stats, "total_dispatches", 0),
              total_merged: Map.get(stats, "total_merged", 0),
              total_rejected: Map.get(stats, "total_rejected", 0)
            }

          _ ->
            state
        end

      {:error, _} ->
        state
    end
  rescue
    _ -> state
  end

  # -- PR Outcome Polling --

  defp poll_pr_outcomes(state) do
    case System.cmd("gh", [
           "pr", "list",
           "--repo", @daemon_repo,
           "--head", "workdir/",
           "--json", "headRefName,state,mergedAt,closedAt",
           "--limit", "50"
         ], stderr_to_stdout: true) do
      {json, 0} ->
        try do
          prs = Jason.decode!(json)

          Enum.reduce(prs, state, fn pr, acc ->
            branch = pr["headRefName"]
            pr_state = pr["state"]
            merged_at = pr["mergedAt"]
            closed_at = pr["closedAt"]

            cond do
              pr_state == "MERGED" and merged_at != nil ->
                Logger.info("[WorkDirector] PR merged: #{branch}")
                handle_pr_merged(acc, branch)

              pr_state in ["CLOSED", "OPEN"] and closed_at != nil ->
                Logger.info("[WorkDirector] PR closed without merge: #{branch}")
                handle_pr_rejected(acc, branch)

              true ->
                acc
            end
          end)
        rescue
          e ->
            Logger.warning("[WorkDirector] Failed to parse PR outcomes: #{Exception.message(e)}")
            state
        catch
          :exit, _ -> state
        end

      {output, _} ->
        Logger.warning("[WorkDirector] PR poll failed: #{String.slice(output, 0, 200)}")
        state
    end
  end

  defp handle_pr_merged(state, branch) do
    case Enum.find(state.completed_prs, fn pr -> pr.branch == branch end) do
      nil ->
        # PR not tracked, ignore
        state

      %{source: source, content_hash: _hash} ->
        # Update Thompson arm
        state = reward_arm(state, source, 1.0)
        state = %{state | total_merged: state.total_merged + 1}

        # Remove from completed PRs tracking
        completed_prs = Enum.reject(state.completed_prs, fn pr -> pr.branch == branch end)
        state = %{state | completed_prs: completed_prs}

        # Persist updated arms
        persist_arms(state)
        state
    end
  end

  defp handle_pr_rejected(state, branch) do
    case Enum.find(state.completed_prs, fn pr -> pr.branch == branch end) do
      nil ->
        # PR not tracked, ignore
        state

      %{source: source, content_hash: _hash} ->
        # Penalize Thompson arm
        state = reward_arm(state, source, 0.1)
        state = %{state | total_rejected: state.total_rejected + 1}

        # Remove from completed PRs tracking
        completed_prs = Enum.reject(state.completed_prs, fn pr -> pr.branch == branch end)
        state = %{state | completed_prs: completed_prs}

        # Persist updated arms
        persist_arms(state)
        state
    end
  end

  defp schedule_pr_poll do
    Process.send_after(self(), :poll_pr_outcomes, @pr_poll_ms)
  end

  # -- Helper Functions --

  defp maybe_reset_daily_counter(state) do
    today = Date.utc_today()
    if state.last_day_reset != today do
      %{state | dispatches_today: 0, last_day_reset: today}
    else
      state
    end
  end

  defp branch_name(%WorkItem{title: title}) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.slice(0, 40)
      |> String.trim_trailing("-")

    "workdir/#{slug}"
  end

  defp reward_arm(state, source, reward) when is_number(reward) do
    case Map.get(state.arms, source) do
      nil ->
        Logger.warning("[WorkDirector] Unknown arm source: #{source}")
        state

      %{alpha: alpha, beta: beta} ->
        # Beta(α+reward, β+(1-reward))
        # reward=1.0 → success: α+=1, β+=0
        # reward=0.0 → failure: α+=0, β+=1
        # reward=0.1 → soft failure: α+=0.1, β+=0.9
        # reward=0.8 → strong success: α+=0.8, β+=0.2
        new_alpha = alpha + reward
        new_beta = beta + (1.0 - reward)
        updated_arms = Map.put(state.arms, source, %{alpha: new_alpha, beta: new_beta})

        %{state | arms: updated_arms}
    end
  end

  defp add_completed_pr(state, branch, source, content_hash) do
    completed = %{
      branch: branch,
      source: source,
      content_hash: content_hash,
      created_at: DateTime.utc_now()
    }

    completed_prs = [completed | state.completed_prs] |> Enum.take(@max_completed_prs)
    %{state | completed_prs: completed_prs}
  end

  defp remove_completed_pr(state, branch) do
    completed_prs = Enum.reject(state.completed_prs, fn pr -> pr.branch == branch end)
    %{state | completed_prs: completed_prs}
  end

  defp failure_class_reward(:compilation_error), do: 0.2
  defp failure_class_reward(:phantom_references), do: 0.1
  defp failure_class_reward(:stub_detected), do: 0.05
  defp failure_class_reward(:timeout), do: 0.3
  defp failure_class_reward(:orchestrator_error), do: 0.25
  defp failure_class_reward(:commit_error), do: 0.15
  defp failure_class_reward(:no_branch_created), do: 0.0
  defp failure_class_reward(:empty_branch), do: 0.1
  defp failure_class_reward(:process_crash), do: 0.0
  defp failure_class_reward(:unknown), do: 0.1

  defp update_backlog_completed(state, content_hash, result) do
    case Map.get(state.backlog, content_hash) do
      nil -> state
      item ->
        updated_item = %{item | status: :completed, result: result, pr_branch: elem(result, 1)}
        %{state | backlog: Map.put(state.backlog, content_hash, updated_item)}
    end
  end

  defp update_backlog_failed(state, content_hash, error_info) do
    case Map.get(state.backlog, content_hash) do
      nil -> state
      item ->
        updated_item = %{item |
          status: :failed,
          attempt_count: item.attempt_count + 1,
          last_failure_class: error_info.class,
          last_failure_reason: error_info.reason
        }
        %{state | backlog: Map.put(state.backlog, content_hash, updated_item)}
    end
  end

  defp verify_safety(branch) do
    # Check if branch only modifies allowed files
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))

    {output, _} = System.cmd("git", ["diff", "--name-only", "main...#{branch}", "--", "*.ex", "*.exs"],
      cd: repo_path, stderr_to_stdout: true)

    changed_files = output |> String.split() |> Enum.filter(&(&1 != ""))

    forbidden =
      Enum.any?(state_blocked_regexes(), fn regex ->
        Enum.any?(changed_files, fn file -> Regex.match?(regex, file) end)
      end)

    if forbidden do
      :unsafe
    else
      :safe
    end
  end

  defp state_blocked_regexes do
    # This is a bit of a hack - we need to access @blocked_regexes from state
    # In a proper refactor, this would be passed in init/1
    Application.get_env(:daemon, :work_director_blocked_patterns, [])
    |> Enum.map(&Regex.compile!/1)
  end

  defp delete_branch(branch) do
    repo_path = Application.get_env(:daemon, :repo_path, Path.expand("~/vas-swarm"))
    System.cmd("git", ["branch", "-D", branch], cd: repo_path, stderr_to_stdout: true)
    System.cmd("git", ["push", "origin", "--delete", branch], cd: repo_path, stderr_to_stdout: true)
    :ok
  end
end
