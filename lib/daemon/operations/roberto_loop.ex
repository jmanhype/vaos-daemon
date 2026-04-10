defmodule Daemon.Operations.RobertoLoop do
  @moduledoc """
  Durable long-horizon control-plane helpers for the Roberto hardening program.

  This module treats the repo-local SPEC/PLAN/IMPLEMENT/STATUS files as the
  operator-facing entrypoints and can synthesize a resumable snapshot for the
  next session or automation step.
  """

  @root_files %{
    spec: "SPEC.md",
    plan: "PLAN.md",
    implement: "IMPLEMENT.md",
    status: "STATUS.md"
  }

  @canonical_files %{
    spec: "docs/operations/roberto-content/Prompt.md",
    plan: "docs/operations/roberto-content/Plan.md",
    implement: "docs/operations/roberto-content/Implement.md",
    status: "docs/operations/roberto-content/Documentation.md"
  }

  @doc false
  def control_paths(base \\ File.cwd!()) do
    %{
      root: expand_paths(base, @root_files),
      canonical: expand_paths(base, @canonical_files)
    }
  end

  @doc false
  def resume_summary(base \\ File.cwd!()) do
    paths = control_paths(base)
    status_text = File.read!(paths.root.status)

    %{
      paths: paths,
      epic_id: capture_field(status_text, ~r/\*\*Epic\*\*:\s+`([^`]+)`/),
      current_issue: capture_field(status_text, ~r/\*\*Current active issue\*\*:\s+`([^`]+)`/),
      latest_trace: capture_field(status_text, ~r/\*\*Latest trace\*\*:\s+\[[^\]]+\]\(([^)]+)\)/),
      canonical_status: capture_field(status_text, ~r/\*\*Canonical status\*\*:\s+\[[^\]]+\]\(([^)]+)\)/),
      next_roberto_step:
        capture_field(status_text, ~r/\*\*Next Roberto step\*\*:\s+(.+)/),
      resume_steps: extract_resume_steps(status_text),
      missing_files: missing_files(paths)
    }
  end

  @doc false
  def complete?(summary) when is_map(summary) do
    summary.missing_files == [] and is_binary(summary.current_issue) and summary.current_issue != ""
  end

  defp expand_paths(base, mapping) do
    Map.new(mapping, fn {key, relative} ->
      {key, Path.expand(relative, base)}
    end)
  end

  defp capture_field(text, regex) do
    case Regex.run(regex, text, capture: :all_but_first) do
      [value] -> String.trim(value)
      _ -> nil
    end
  end

  defp extract_resume_steps(text) do
    case String.split(text, "## Resume", parts: 2) do
      [_before, after_resume] ->
        after_resume
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.match?(&1, ~r/^\d+\./))

      _ ->
        []
    end
  end

  defp missing_files(%{root: root_paths, canonical: canonical_paths}) do
    (Map.values(root_paths) ++ Map.values(canonical_paths))
    |> Enum.reject(&File.exists?/1)
  end
end
