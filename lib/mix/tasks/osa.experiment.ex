defmodule Mix.Tasks.Osa.Experiment do
  @moduledoc """
  Run WorkDirector A/B experiments.

  ## Commands

      mix osa.experiment list                    # Show available experiments
      mix osa.experiment flags                   # Show current flag values
      mix osa.experiment run E0_baseline         # Run a single experiment
      mix osa.experiment run E0_baseline --task-set medium  # With specific task set
      mix osa.experiment run E0_baseline --dry-run          # Preview without executing
      mix osa.experiment matrix                  # Run full experiment matrix
      mix osa.experiment matrix --task-set small # Matrix with specific task set
      mix osa.experiment results                 # Show comparison table
      mix osa.experiment results E0_baseline     # Show single experiment results
      mix osa.experiment reset                   # Clear backlog and blacklist

  ## Task Sets

  - `small` — 3 single-file tasks (default)
  - `medium` — 4 multi-concern tasks
  - `large` — 3 complex tasks
  - `full` — all 10 tasks combined

  ## Profiles

  Set `DAEMON_WD_PROFILE=full` to enable all flags before running.
  Set `DAEMON_WD_PROFILE=minimal` to disable all flags.
  """
  use Mix.Task

  alias Daemon.Agent.WorkDirector
  alias Daemon.Agent.WorkDirector.Experiment

  @shortdoc "Run WorkDirector A/B experiments"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [
      task_set: :string,
      dry_run: :boolean
    ], aliases: [t: :task_set, n: :dry_run])

    case positional do
      ["list"] -> cmd_list()
      ["flags"] -> cmd_flags()
      ["run", name | _] -> cmd_run(name, opts)
      ["matrix" | _] -> cmd_matrix(opts)
      ["results"] -> cmd_compare()
      ["results", name | _] -> cmd_results(name)
      ["reset"] -> cmd_reset()
      _ -> cmd_help()
    end
  end

  defp cmd_list do
    experiments = Experiment.list_experiments()
    Mix.shell().info("\nAvailable experiments:\n")
    Mix.shell().info(String.pad_trailing("Name", 28) <> String.pad_trailing("Flags", 8) <> "Description")
    Mix.shell().info(String.duplicate("-", 80))

    for %{name: name, description: desc, flags_on: count} <- experiments do
      Mix.shell().info(
        String.pad_trailing(name, 28) <>
        String.pad_trailing("#{count}", 8) <>
        desc
      )
    end

    Mix.shell().info("\nTask sets: small (3), medium (4), large (3), full (10)")
  end

  defp cmd_flags do
    Mix.shell().info("\nWorkDirector Feature Flags:\n")
    flags = WorkDirector.feature_flags()

    for {flag, enabled} <- Enum.sort(flags) do
      status = if enabled, do: "ON ", else: "OFF"
      color = if enabled, do: :green, else: :red
      Mix.shell().info([color, "  [#{status}] ", :reset, to_string(flag)])
    end

    on_count = Enum.count(flags, fn {_, v} -> v end)
    Mix.shell().info("\n#{on_count}/#{map_size(flags)} flags enabled")
  end

  defp cmd_run(name, opts) do
    ensure_started()

    task_set = Keyword.get(opts, :task_set, "small")
    dry_run = Keyword.get(opts, :dry_run, false)

    Mix.shell().info("\nRunning experiment: #{name} (task_set=#{task_set}, dry_run=#{dry_run})")

    case Experiment.run(name, task_set: task_set, dry_run: dry_run) do
      %{dry_run: true} = result ->
        Mix.shell().info("\nDry run preview:")
        Mix.shell().info("  Tasks: #{result.task_count}")
        Mix.shell().info("  Flags ON: #{inspect(flags_on(result.flags_snapshot))}")

      %{} = result ->
        Mix.shell().info("\nResults:")
        Mix.shell().info("  Dispatched: #{result.dispatched_count}/#{result.task_count}")
        Mix.shell().info("  Succeeded: #{result.success_count}")
        Mix.shell().info("  Failed: #{result.failure_count}")
        Mix.shell().info("  Success rate: #{Float.round(result.success_rate * 100, 1)}%")
        Mix.shell().info("  Avg duration: #{result.avg_duration_ms}ms")

      {:error, msg} ->
        Mix.shell().error("Error: #{msg}")
    end
  end

  defp cmd_matrix(opts) do
    ensure_started()

    task_set = Keyword.get(opts, :task_set, "small")
    Mix.shell().info("\nRunning full experiment matrix (task_set=#{task_set})...")
    Mix.shell().info("This will run 15 experiments sequentially.\n")

    result = Experiment.run_matrix(task_set: task_set)
    Mix.shell().info("\nMatrix complete: #{result.experiments} experiments")
    print_comparison(result.results)
  end

  defp cmd_compare do
    results = Experiment.compare()

    if results == [] do
      Mix.shell().info("\nNo experiment results found. Run experiments first.")
    else
      Mix.shell().info("\nExperiment Comparison (sorted by success rate):\n")
      print_comparison(results)
    end
  end

  defp cmd_results(name) do
    case Experiment.results(name) do
      {:ok, data} ->
        Mix.shell().info("\nResults for #{name}:")
        Mix.shell().info(Jason.encode!(data, pretty: true))
      {:error, msg} ->
        Mix.shell().error("Error: #{msg}")
    end
  end

  defp cmd_reset do
    Experiment.reset!()
    Mix.shell().info("WorkDirector backlog and blacklist cleared.")
  end

  defp cmd_help do
    Mix.shell().info(@moduledoc)
  end

  defp print_comparison(results) when is_list(results) do
    Mix.shell().info(
      String.pad_trailing("Experiment", 28) <>
      String.pad_trailing("Rate", 8) <>
      String.pad_trailing("Succ", 6) <>
      String.pad_trailing("Total", 7) <>
      String.pad_trailing("Avg ms", 10) <>
      "Flags ON"
    )
    Mix.shell().info(String.duplicate("-", 90))

    for row <- results do
      rate = Map.get(row, :success_rate) || Map.get(row, "success_rate") || 0
      succ = Map.get(row, :success_count) || Map.get(row, "success_count") || 0
      total = Map.get(row, :task_count) || Map.get(row, "task_count") || 0
      avg = Map.get(row, :avg_duration_ms) || Map.get(row, "avg_duration_ms") || 0
      flags = Map.get(row, :flags_on) || Map.get(row, "flags_on") || []
      name = Map.get(row, :experiment) || Map.get(row, "experiment") || "?"

      Mix.shell().info(
        String.pad_trailing(to_string(name), 28) <>
        String.pad_trailing("#{Float.round(rate * 100, 1)}%", 8) <>
        String.pad_trailing("#{succ}", 6) <>
        String.pad_trailing("#{total}", 7) <>
        String.pad_trailing("#{avg}", 10) <>
        inspect(flags)
      )
    end
  end

  defp flags_on(flags_map) do
    flags_map
    |> Enum.filter(fn {_k, v} -> v end)
    |> Enum.map(fn {k, _v} -> k end)
    |> Enum.sort()
  end

  defp ensure_started do
    Mix.Task.run("app.start")
  end
end
