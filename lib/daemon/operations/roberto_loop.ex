defmodule Daemon.Operations.RobertoLoop do
  @moduledoc """
  Durable long-horizon control-plane helpers for the Roberto hardening program.

  This module treats the repo-local SPEC/PLAN/IMPLEMENT/STATUS files as the
  operator-facing entrypoints and can synthesize a resumable snapshot for the
  next session or automation step.
  """

  @prompt_intro """
  You are resuming the Roberto long-horizon hardening program in this repository.

  This is an autonomous Codex slice, not a blank chat. Treat the repo-local
  Roberto control files plus the current Beads issue as the operating contract.
  Work only the current first-order bottleneck, preserve unrelated local changes,
  and close the slice with tests, status updates, Beads updates, commit, sync,
  and push when the work is actually complete.
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
      canonical_status:
        capture_field(status_text, ~r/\*\*Canonical status\*\*:\s+\[[^\]]+\]\(([^)]+)\)/),
      next_roberto_step: capture_field(status_text, ~r/\*\*Next Roberto step\*\*:\s+(.+)/),
      resume_steps: extract_resume_steps(status_text),
      missing_files: missing_files(paths)
    }
  end

  @doc false
  def codex_prompt(base \\ File.cwd!(), opts \\ []) do
    summary = resume_summary(base)

    issue_output =
      Keyword.get_lazy(opts, :issue_output, fn -> issue_output(summary.current_issue) end)

    [
      String.trim(@prompt_intro),
      "",
      "Working root: #{base}",
      "Epic: #{summary.epic_id}",
      "Current active issue: #{summary.current_issue}",
      "Canonical status: #{summary.canonical_status}",
      "Latest trace: #{summary.latest_trace}",
      "Next Roberto step: #{summary.next_roberto_step}",
      "",
      "Read these entry files first:",
      "* #{summary.paths.root.status}",
      "* #{summary.paths.root.spec}",
      "* #{summary.paths.root.plan}",
      "* #{summary.paths.root.implement}",
      "* #{summary.paths.canonical.spec}",
      "* #{summary.paths.canonical.status}",
      "* #{summary.paths.canonical.plan}",
      "* #{summary.paths.canonical.implement}",
      "",
      "Operating rules:",
      "1. Read the current active issue and the exact trace or artifact that exposed it.",
      "2. Fix the narrowest generic layer that explains the failure.",
      "3. Do not drift into topic-specific or profile-specific salvage unless it is explicit temporary debt.",
      "4. Run targeted tests and one live validation or equivalent runtime artifact.",
      "5. Update Documentation.md, STATUS.md, and the Beads issue before stopping.",
      "6. Respect unrelated dirty files in the worktree; do not revert or bundle them.",
      "7. Stage and commit only the files that belong to this slice.",
      "8. Finish with `git pull --rebase`, `scripts/bd-safe --no-daemon sync`, `git push`, and a final `git status` check.",
      "",
      "Current Beads issue:",
      issue_output || "(issue output unavailable)"
    ]
    |> Enum.join("\n")
  end

  @doc false
  def complete?(summary) when is_map(summary) do
    summary.missing_files == [] and is_binary(summary.current_issue) and
      summary.current_issue != ""
  end

  @doc false
  def issue_output(nil), do: nil

  def issue_output(issue_id) do
    bash = System.find_executable("bash") || "/bin/bash"

    case System.cmd(bash, ["scripts/bd-safe", "show", issue_id], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, _code} -> "Failed to load issue #{issue_id}: #{String.trim(output)}"
    end
  rescue
    _ -> "Failed to execute scripts/bd-safe show #{issue_id}"
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
