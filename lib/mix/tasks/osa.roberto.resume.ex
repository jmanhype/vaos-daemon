defmodule Mix.Tasks.Osa.Roberto.Resume do
  @moduledoc """
  Resume the long-horizon Roberto hardening program from repo memory and Beads.

  Usage:

      mix osa.roberto.resume
      mix osa.roberto.resume --json
      mix osa.roberto.resume --check
  """

  use Mix.Task

  alias Daemon.Operations.RobertoLoop

  @shortdoc "Resume the Roberto long-horizon hardening loop"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          check: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    summary = RobertoLoop.resume_summary()
    issue_output = beads_show(summary.current_issue)

    if opts[:json] do
      Mix.shell().info(
        Jason.encode!(Map.put(summary, :issue_output, issue_output), pretty: true)
      )
    else
      print_summary(summary, issue_output)
    end

    if opts[:check] do
      if not RobertoLoop.complete?(summary) do
        Mix.raise("Roberto loop is not ready: missing files or active issue")
      end
    end
  end

  defp print_summary(summary, issue_output) do
    Mix.shell().info("Roberto Program")
    Mix.shell().info("Epic: #{summary.epic_id}")
    Mix.shell().info("Current issue: #{summary.current_issue}")
    Mix.shell().info("Canonical status: #{summary.canonical_status}")
    Mix.shell().info("Latest trace: #{summary.latest_trace}")
    Mix.shell().info("Next Roberto step: #{summary.next_roberto_step}")
    Mix.shell().info("")
    Mix.shell().info("Entry files:")
    Mix.shell().info("* SPEC: #{summary.paths.root.spec}")
    Mix.shell().info("* PLAN: #{summary.paths.root.plan}")
    Mix.shell().info("* IMPLEMENT: #{summary.paths.root.implement}")
    Mix.shell().info("* STATUS: #{summary.paths.root.status}")

    if summary.resume_steps != [] do
      Mix.shell().info("")
      Mix.shell().info("Resume checklist:")
      Enum.each(summary.resume_steps, &Mix.shell().info("* #{&1}"))
    end

    if summary.missing_files != [] do
      Mix.shell().error("")
      Mix.shell().error("Missing files:")
      Enum.each(summary.missing_files, &Mix.shell().error("* #{&1}"))
    end

    if issue_output do
      Mix.shell().info("")
      Mix.shell().info("Beads issue:")
      Mix.shell().info(issue_output)
    end
  end

  defp beads_show(nil), do: nil

  defp beads_show(issue_id) do
    bash = System.find_executable("bash") || "/bin/bash"

    case System.cmd(bash, ["scripts/bd-safe", "show", issue_id], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, _code} -> "Failed to load issue #{issue_id}: #{String.trim(output)}"
    end
  rescue
    _ -> "Failed to execute scripts/bd-safe show #{issue_id}"
  end
end
