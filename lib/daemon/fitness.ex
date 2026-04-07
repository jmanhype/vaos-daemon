defmodule Daemon.Fitness do
  @moduledoc """
  Architectural fitness functions — executable desired-state predicates.

  Each fitness function is a deterministic guard that returns:
  - `{:kept, score, detail}` — invariant holds
  - `{:not_kept, score, detail}` — invariant violated, detail explains how

  No LLM involvement. These are Boolean assertions about codebase health.

  ## FreezingArchRule

  On first run, existing violations are snapshotted into
  `~/.daemon/frozen_violations/`. Subsequent runs only act on NEW violations —
  violations not present in the frozen snapshot. When violations are fixed,
  they're removed from the frozen store (ratchet effect).
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback evaluate(workspace :: String.t()) :: {:kept | :not_kept, float(), String.t()}

  @fitness_modules [
    Daemon.Fitness.CompileCheck,
    Daemon.Fitness.TestSuite,
    Daemon.Fitness.EventConsumers
  ]

  def all, do: @fitness_modules

  def evaluate_all(workspace) do
    Enum.map(@fitness_modules, fn mod ->
      try do
        result = mod.evaluate(workspace)
        {mod.name(), result}
      rescue
        e -> {mod.name(), {:not_kept, 0.0, "Fitness function crashed: #{Exception.message(e)}"}}
      catch
        kind, reason -> {mod.name(), {:not_kept, 0.0, "Fitness function #{kind}: #{inspect(reason)}"}}
      end
    end)
  end

  # --- FreezingArchRule Store ---

  @frozen_dir "~/.daemon/frozen_violations"

  def load_frozen(fitness_name) do
    path = frozen_path(fitness_name)

    case File.read(path) do
      {:ok, json} -> Jason.decode!(json) |> MapSet.new()
      {:error, _} -> MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  end

  def save_frozen(fitness_name, violations) do
    path = frozen_path(fitness_name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(MapSet.to_list(violations), pretty: true))
  end

  def apply_frozen_filter(fitness_name, {:kept, score, detail}) do
    _ = fitness_name
    {:kept, score, detail}
  end

  def apply_frozen_filter(fitness_name, {:not_kept, score, detail}) do
    frozen = load_frozen(fitness_name)
    current = parse_violations(detail)
    new_violations = MapSet.difference(current, frozen)
    fixed = MapSet.difference(frozen, current)

    # Ratchet: remove fixed violations from frozen store
    unless MapSet.equal?(fixed, MapSet.new()) do
      save_frozen(fitness_name, MapSet.difference(frozen, fixed))
    end

    if MapSet.size(new_violations) == 0 do
      {:kept, score, "#{MapSet.size(frozen)} known violations remaining (#{MapSet.size(fixed)} fixed this cycle)"}
    else
      {:not_kept, score, "NEW violations:\n" <> Enum.join(MapSet.to_list(new_violations), "\n")}
    end
  end

  defp parse_violations(detail) do
    detail |> String.split("\n") |> Enum.reject(&(&1 == "")) |> MapSet.new()
  end

  defp frozen_path(name) do
    Path.expand("#{@frozen_dir}/#{name}.json")
  end

  @doc """
  Snapshot current violations to initialize the frozen store.
  Called once on first cycle to establish the frozen baseline.
  """
  def freeze_current!(workspace) do
    Enum.each(all(), fn mod ->
      case mod.evaluate(workspace) do
        {:not_kept, _score, detail} ->
          violations = parse_violations(detail)
          save_frozen(mod.name(), violations)

        {:kept, _, _} ->
          save_frozen(mod.name(), MapSet.new())
      end
    end)
  end
end
