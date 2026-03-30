defmodule Daemon.Agent.WorkDirector.Experiment do
  @moduledoc """
  A/B experiment harness for WorkDirector feature flags.

  Runs standardized task sets against different flag configurations to measure
  which features help vs hurt the autonomous code generation pipeline.

  Results are persisted to `~/.daemon/work_director/experiments/` as JSON.
  """
  require Logger

  alias Daemon.Agent.WorkDirector
  alias Daemon.Agent.WorkDirector.Backlog
  alias Daemon.Events.Bus

  @results_dir Path.expand("~/.daemon/work_director/experiments")
  @completion_poll_ms 5_000
  @completion_timeout_ms :timer.minutes(30)

  # -- Experiment Definitions --

  @experiments %{
    "E0_baseline" => %{
      description: "Raw pipeline baseline — no features enabled",
      flags: %{}
    },
    "E1_substance_check" => %{
      description: "Stub detection value",
      flags: %{wd_enable_substance_check: true}
    },
    "E2_test_gate" => %{
      description: "Hard test gate value",
      flags: %{wd_enable_test_gate: true}
    },
    "E3_autofixer" => %{
      description: "AutoFixer vs simple retry",
      flags: %{wd_enable_autofixer: true}
    },
    "E4_code_review" => %{
      description: "Peer review value",
      flags: %{wd_enable_code_review: true}
    },
    "E5_vault_context" => %{
      description: "Memory injection value",
      flags: %{wd_enable_vault_context: true}
    },
    "E6_specialist_routing" => %{
      description: "Role-based prompting value",
      flags: %{wd_enable_specialist_routing: true}
    },
    "E7_risk_assessment" => %{
      description: "Risk scoring value",
      flags: %{wd_enable_risk_assessment: true}
    },
    "E8_strategic_rejection" => %{
      description: "Invariant guard value",
      flags: %{wd_enable_strategic_rejection: true}
    },
    "E9_dispatch_confidence" => %{
      description: "Confidence routing value",
      flags: %{wd_enable_dispatch_confidence: true}
    },
    "E10_already_solved" => %{
      description: "Duplicate detection value",
      flags: %{wd_enable_already_solved_check: true}
    },
    "E11_quality_gates" => %{
      description: "All gates compound effect",
      flags: %{
        wd_enable_substance_check: true, wd_enable_test_gate: true,
        wd_enable_autofixer: true, wd_enable_code_review: true
      }
    },
    "E12_context_enrichment" => %{
      description: "All context compound effect",
      flags: %{
        wd_enable_vault_context: true, wd_enable_knowledge_context: true,
        wd_enable_appraiser: true, wd_enable_specialist_routing: true,
        wd_enable_impact_analysis: true
      }
    },
    "E13_gates_only" => %{
      description: "All pre-dispatch gates compound",
      flags: %{
        wd_enable_risk_assessment: true, wd_enable_strategic_rejection: true,
        wd_enable_dispatch_confidence: true, wd_enable_already_solved_check: true
      }
    },
    "E14_all_flags" => %{
      description: "Full system vs baseline",
      flags: Enum.into(
        Enum.map(WorkDirector.all_flag_keys(), &{&1, true}),
        %{}
      )
    }
  }

  # -- Standard Task Sets --

  @task_sets %{
    "small" => [
      %{title: "Add @moduledoc to Daemon.Events.Classifier", description: "Add a @moduledoc string to lib/daemon/events/classifier.ex describing the module's purpose.", priority: 0.3},
      %{title: "Remove unused alias in Daemon.Agent.Loop", description: "Find and remove any unused alias statements in lib/daemon/agent/loop.ex. Run mix compile --warnings-as-errors to verify.", priority: 0.2},
      %{title: "Add @spec to Bus.emit/3", description: "Add a @spec annotation to Daemon.Events.Bus.emit/3 matching its existing @doc typespec.", priority: 0.3}
    ],
    "medium" => [
      %{title: "Add telemetry event for provider failover", description: "Emit a :telemetry.execute event when Daemon.Providers.Registry falls back to the next provider in the failover chain. Include provider name and attempt count.", priority: 0.5},
      %{title: "Add WorkDirector.feature_flags/0 to HTTP API", description: "Add GET /api/v1/work-director/flags endpoint that returns the current feature flag state as JSON.", priority: 0.5},
      %{title: "Add JSON formatter for Logger", description: "Create a Logger backend formatter that outputs structured JSON logs with timestamp, level, message, and metadata. Wire it up as an optional config.", priority: 0.6},
      %{title: "Fix delegation cycle in MiosaMemory.Store", description: "Audit lib/miosa/shims.ex for any remaining circular delegation patterns between Miosa* and Daemon* modules. Fix any found.", priority: 0.6}
    ],
    "large" => [
      %{title: "Add GET /api/v1/work-director/experiments endpoint", description: "Create a new HTTP endpoint that returns experiment results from ~/.daemon/work_director/experiments/ as JSON. Include proper error handling for missing files.", priority: 0.7},
      %{title: "Add WebSocket channel for real-time dispatch events", description: "Create a Phoenix Channel that broadcasts work_dispatched and work_dispatch_complete events to connected clients in real-time.", priority: 0.8},
      %{title: "Add SQLite migration for experiment results", description: "Create a new SQLite table 'experiment_runs' with columns: id, name, flags_json, task_count, success_count, duration_ms, created_at. Add Ecto schema and migration.", priority: 0.8}
    ],
    "full" => :all  # computed at runtime from small + medium + large
  }

  # -- Public API --

  @doc "List available experiments."
  def list_experiments do
    @experiments
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {name, %{description: desc, flags: flags}} ->
      %{name: name, description: desc, flags_on: map_size(flags)}
    end)
  end

  @doc "Get a task set by name. Returns list of task maps."
  def task_set(name) do
    case Map.get(@task_sets, name) do
      :all ->
        Enum.flat_map(["small", "medium", "large"], &Map.get(@task_sets, &1, []))

      nil ->
        {:error, "Unknown task set: #{name}. Available: #{inspect(Map.keys(@task_sets))}"}

      tasks ->
        tasks
    end
  end

  @doc """
  Run a single experiment.

  Sets flags via Application.put_env, resets WorkDirector state,
  submits tasks, and collects results.
  """
  def run(experiment_name, opts \\ []) do
    task_set_name = Keyword.get(opts, :task_set, "small")
    dry_run = Keyword.get(opts, :dry_run, false)

    with {:ok, experiment} <- get_experiment(experiment_name),
         {:ok, tasks} <- resolve_tasks(task_set_name) do

      Logger.info("[Experiment] Starting #{experiment_name} (#{length(tasks)} tasks, flags=#{map_size(experiment.flags)})")

      # 1. Reset all flags to false
      reset_flags!()

      # 2. Set experiment flags
      set_flags(experiment.flags)

      # 3. Snapshot active flags
      flags_snapshot = WorkDirector.feature_flags()
      Logger.info("[Experiment] Active flags: #{inspect(flags_on(flags_snapshot))}")

      if dry_run do
        %{
          experiment: experiment_name,
          description: experiment.description,
          task_set: task_set_name,
          task_count: length(tasks),
          flags_snapshot: flags_snapshot,
          dry_run: true
        }
      else
        # 4. Reset WorkDirector backlog
        reset!()

        # 5. Subscribe to completion events
        completion_events = collect_completions(tasks)

        # 6. Submit tasks
        submit_tasks(tasks)

        # 7. Wait for all completions
        results = wait_for_completions(completion_events, length(tasks))

        # 8. Compute summary
        summary = summarize(experiment_name, experiment, task_set_name, tasks, results, flags_snapshot)

        # 9. Persist results
        persist_results(experiment_name, summary)

        Logger.info("[Experiment] #{experiment_name} complete: #{summary.success_count}/#{summary.task_count} succeeded")
        summary
      end
    end
  end

  @doc "Run all experiments sequentially."
  def run_matrix(opts \\ []) do
    task_set_name = Keyword.get(opts, :task_set, "small")

    experiments = @experiments
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {name, _} -> name end)

    Logger.info("[Experiment] Starting matrix run: #{length(experiments)} experiments")

    results = Enum.map(experiments, fn name ->
      Logger.info("[Experiment] --- #{name} ---")
      result = run(name, task_set: task_set_name)
      # Reset between experiments
      reset_flags!()
      reset!()
      Process.sleep(2_000)
      {name, result}
    end)

    # Produce comparison
    comparison = compare_results(results)
    persist_results("_matrix_#{task_set_name}", comparison)
    comparison
  end

  @doc "Read persisted results for an experiment."
  def results(experiment_name) do
    path = results_path(experiment_name)
    case File.read(path) do
      {:ok, content} -> Jason.decode(content)
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
  end

  @doc "Compare all persisted experiment results."
  def compare do
    File.mkdir_p!(@results_dir)

    @results_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.reject(&String.starts_with?(&1, "_"))
    |> Enum.sort()
    |> Enum.map(fn file ->
      path = Path.join(@results_dir, file)
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} -> data
            _ -> nil
          end
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn r -> -(Map.get(r, "success_rate", 0)) end)
  end

  @doc "Reset WorkDirector backlog and blacklist."
  def reset! do
    try do
      Backlog.clear_blacklist()
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
    :ok
  end

  # -- Private Helpers --

  defp get_experiment(name) do
    case Map.get(@experiments, name) do
      nil -> {:error, "Unknown experiment: #{name}. Available: #{inspect(Map.keys(@experiments) |> Enum.sort())}"}
      exp -> {:ok, exp}
    end
  end

  defp resolve_tasks(task_set_name) do
    case task_set(task_set_name) do
      {:error, _} = err -> err
      tasks -> {:ok, tasks}
    end
  end

  defp reset_flags! do
    for key <- WorkDirector.all_flag_keys() do
      Application.put_env(:daemon, key, false)
    end
    :ok
  end

  defp set_flags(flags) do
    for {key, value} <- flags do
      Application.put_env(:daemon, key, value)
    end
    :ok
  end

  defp flags_on(flags_map) do
    flags_map
    |> Enum.filter(fn {_k, v} -> v end)
    |> Enum.map(fn {k, _v} -> k end)
    |> Enum.sort()
  end

  defp submit_tasks(tasks) do
    for task <- tasks do
      priority = Map.get(task, :priority, 0.5)
      WorkDirector.submit(task.title, task.description, priority)
    end
  end

  defp collect_completions(_tasks) do
    # Register a temporary event handler for completion events.
    ref = make_ref()
    parent = self()

    Bus.register_handler(:work_dispatch_complete, fn event ->
      send(parent, {:experiment_completion, ref, event})
    end)

    ref
  end

  defp wait_for_completions(ref, expected_count) do
    deadline = System.monotonic_time(:millisecond) + @completion_timeout_ms
    do_wait(ref, expected_count, [], deadline)
  end

  defp do_wait(_ref, 0, acc, _deadline), do: Enum.reverse(acc)
  defp do_wait(ref, remaining, acc, deadline) do
    now = System.monotonic_time(:millisecond)
    timeout = max(deadline - now, 0)

    if timeout <= 0 do
      Logger.warning("[Experiment] Timeout waiting for #{remaining} more completions")
      Enum.reverse(acc)
    else
      receive do
        {:experiment_completion, ^ref, event} ->
          do_wait(ref, remaining - 1, [event | acc], deadline)
      after
        min(timeout, @completion_poll_ms) ->
          # Check if WorkDirector is still dispatching
          if WorkDirector.dispatching?() do
            do_wait(ref, remaining, acc, deadline)
          else
            Logger.info("[Experiment] WorkDirector idle, #{remaining} tasks may not have been dispatched")
            Enum.reverse(acc)
          end
      end
    end
  end

  defp summarize(name, experiment, task_set_name, tasks, results, flags_snapshot) do
    successes = Enum.count(results, fn r ->
      case r do
        %{outcome: :success} -> true
        %{"outcome" => "success"} -> true
        _ -> false
      end
    end)

    total_duration = Enum.reduce(results, 0, fn r, acc ->
      duration = Map.get(r, :duration_ms) || Map.get(r, "duration_ms") || 0
      acc + duration
    end)

    %{
      experiment: name,
      description: experiment.description,
      task_set: task_set_name,
      task_count: length(tasks),
      dispatched_count: length(results),
      success_count: successes,
      failure_count: length(results) - successes,
      success_rate: if(length(results) > 0, do: successes / length(results), else: 0.0),
      total_duration_ms: total_duration,
      avg_duration_ms: if(length(results) > 0, do: div(total_duration, length(results)), else: 0),
      flags_snapshot: flags_snapshot,
      flags_on: flags_on(flags_snapshot),
      results: Enum.map(results, &sanitize_result/1),
      completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp sanitize_result(event) when is_map(event) do
    %{
      title: Map.get(event, :title) || Map.get(event, "title"),
      outcome: Map.get(event, :outcome) || Map.get(event, "outcome"),
      duration_ms: Map.get(event, :duration_ms) || Map.get(event, "duration_ms")
    }
  end

  defp persist_results(name, data) do
    File.mkdir_p!(@results_dir)
    path = results_path(name)

    case Jason.encode(data, pretty: true) do
      {:ok, json} -> File.write!(path, json)
      {:error, reason} -> Logger.error("[Experiment] Failed to persist #{name}: #{inspect(reason)}")
    end
  end

  defp results_path(name) do
    safe_name = String.replace(name, ~r/[^a-zA-Z0-9_-]/, "_")
    Path.join(@results_dir, "#{safe_name}.json")
  end

  defp compare_results(results) do
    rows = Enum.map(results, fn
      {name, %{success_rate: rate, success_count: succ, task_count: total, avg_duration_ms: avg_ms, flags_on: flags}} ->
        %{experiment: name, success_rate: rate, success_count: succ, task_count: total, avg_duration_ms: avg_ms, flags_on: flags}
      {name, %{} = summary} ->
        %{experiment: name, summary: summary}
      {name, other} ->
        %{experiment: name, result: other}
    end)

    %{
      matrix: true,
      experiments: length(rows),
      results: Enum.sort_by(rows, &(-Map.get(&1, :success_rate, 0))),
      completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
