defmodule Mix.Tasks.Osa.Roberto.Codex do
  @moduledoc """
  Launch a non-interactive Codex slice for the Roberto long-horizon program.

  Usage:

      mix osa.roberto.codex
      mix osa.roberto.codex --continuous
      mix osa.roberto.codex --prompt-only
      mix osa.roberto.codex --write-prompt /tmp/roberto-prompt.md
      mix osa.roberto.codex --model gpt-5-codex --output-last-message /tmp/roberto-last.md
  """

  use Mix.Task

  alias Daemon.Codex.CLI
  alias Daemon.Operations.RobertoLoop

  @shortdoc "Launch Codex against the current Roberto program state"
  @default_max_slices 10
  @default_pause_seconds 5
  @default_idle_timeout_seconds 900
  @default_max_idle_retries 2
  @idle_timeout_exit_code 124

  @impl true
  def run(args) do
    %{prompt: prompt} = invocation = build_invocation(args)

    maybe_write_prompt(prompt, invocation.write_prompt)

    if invocation.prompt_only? do
      Mix.shell().info(prompt)
      System.halt(0)
    end

    if invocation.continuous? do
      Mix.shell().info(
        "Starting autonomous Roberto mode (max slices: #{format_max_slices(invocation.max_slices)}, pause: #{invocation.pause_seconds}s, idle timeout: #{format_idle_timeout(invocation.idle_timeout_seconds)}, idle retries: #{format_idle_retries(invocation.max_idle_retries)})"
      )

      run_continuous(invocation, 1, 0)
    else
      case run_slice(invocation) do
        {:ok, 0} ->
          System.halt(0)

        {:idle_timeout, timeout_ms} ->
          Mix.shell().error(
            "Codex hit an idle timeout after #{format_idle_timeout_ms(timeout_ms)}"
          )

          System.halt(@idle_timeout_exit_code)

        {:ok, code} ->
          Mix.shell().error("Codex exited with code #{code}")
          System.halt(code)

        {:error, reason} ->
          Mix.raise("Failed to launch Codex: #{reason}")
      end
    end
  end

  @doc false
  def progress_snapshot(base \\ File.cwd!()) do
    %{
      summary: RobertoLoop.resume_summary(base),
      head: git_head(base)
    }
  end

  @doc false
  def progress_made?(before_snapshot, after_snapshot) do
    Enum.any?([
      before_snapshot.head != after_snapshot.head,
      before_snapshot.summary.current_issue != after_snapshot.summary.current_issue,
      before_snapshot.summary.latest_trace != after_snapshot.summary.latest_trace,
      before_snapshot.summary.next_roberto_step != after_snapshot.summary.next_roberto_step
    ])
  end

  defp run_continuous(invocation, slice_number, consecutive_idle_timeouts) do
    before = progress_snapshot(invocation.base)

    case run_slice(invocation, slice_number) do
      {:ok, 0} ->
        after_snapshot = progress_snapshot(invocation.base)

        cond do
          reached_max_slices?(slice_number, invocation.max_slices) ->
            Mix.shell().info(
              "Stopping Roberto autonomous loop after #{slice_number} slice(s): reached max slices."
            )

            System.halt(0)

          not progress_made?(before, after_snapshot) ->
            Mix.shell().info(
              "Stopping Roberto autonomous loop after slice #{slice_number}: no forward progress detected."
            )

            System.halt(0)

          is_nil(after_snapshot.summary.current_issue) or
              after_snapshot.summary.current_issue == "" ->
            Mix.shell().info(
              "Stopping Roberto autonomous loop after slice #{slice_number}: no active Roberto issue remains."
            )

            System.halt(0)

          true ->
            Mix.shell().info(
              "Slice #{slice_number} advanced Roberto from #{before.summary.current_issue || "(none)"} to #{after_snapshot.summary.current_issue} at #{after_snapshot.head || "(no git head)"}."
            )

            maybe_pause(invocation.pause_seconds)

            next_invocation = build_invocation(invocation.argv, base: invocation.base)
            run_continuous(next_invocation, slice_number + 1, 0)
        end

      {:idle_timeout, timeout_ms} ->
        after_snapshot = progress_snapshot(invocation.base)
        made_progress? = progress_made?(before, after_snapshot)

        idle_timeouts =
          if made_progress? do
            0
          else
            consecutive_idle_timeouts + 1
          end

        cond do
          is_nil(after_snapshot.summary.current_issue) or
              after_snapshot.summary.current_issue == "" ->
            Mix.shell().info(
              "Stopping Roberto autonomous loop after slice #{slice_number}: idle timeout fired, but no active Roberto issue remains."
            )

            System.halt(0)

          reached_max_idle_retries?(idle_timeouts, invocation.max_idle_retries) ->
            Mix.shell().error(
              "Stopping Roberto autonomous loop after slice #{slice_number}: Codex stayed idle for #{format_idle_timeout_ms(timeout_ms)} and exhausted #{format_idle_retries(invocation.max_idle_retries)}."
            )

            System.halt(@idle_timeout_exit_code)

          true ->
            progress_note =
              if made_progress? do
                "progress was detected before the timeout"
              else
                "no forward progress was detected"
              end

            Mix.shell().error(
              "Roberto slice #{slice_number} hit an idle timeout after #{format_idle_timeout_ms(timeout_ms)}; restarting #{after_snapshot.summary.current_issue} because #{progress_note}."
            )

            maybe_pause(invocation.pause_seconds)

            next_invocation = build_invocation(invocation.argv, base: invocation.base)
            run_continuous(next_invocation, slice_number + 1, idle_timeouts)
        end

      {:ok, code} ->
        Mix.shell().error(
          "Roberto autonomous loop stopped: Codex exited with code #{code} on slice #{slice_number}."
        )

        System.halt(code)

      {:error, reason} ->
        Mix.raise("Failed to launch Codex on slice #{slice_number}: #{reason}")
    end
  end

  defp run_slice(invocation, slice_number \\ nil) do
    announce_slice(invocation.summary, slice_number)
    CLI.run_exec(invocation.prompt, invocation.codex_opts)
  end

  defp announce_slice(summary, nil) do
    Mix.shell().info("Launching Codex for Roberto issue #{summary.current_issue}")
    Mix.shell().info("Latest trace: #{summary.latest_trace}")
    Mix.shell().info("Next step: #{summary.next_roberto_step}")
    Mix.shell().info("")
  end

  defp announce_slice(summary, slice_number) do
    Mix.shell().info("Launching Roberto slice #{slice_number} for issue #{summary.current_issue}")
    Mix.shell().info("Latest trace: #{summary.latest_trace}")
    Mix.shell().info("Next step: #{summary.next_roberto_step}")
    Mix.shell().info("")
  end

  defp maybe_pause(seconds) when is_integer(seconds) and seconds > 0 do
    Mix.shell().info("Waiting #{seconds}s before the next Roberto slice...")
    Process.sleep(seconds * 1_000)
  end

  defp maybe_pause(_seconds), do: :ok

  defp format_max_slices(0), do: "unlimited"
  defp format_max_slices(value), do: Integer.to_string(value)

  defp format_idle_timeout(0), do: "disabled"

  defp format_idle_timeout(value) when is_integer(value) and value > 0 do
    "#{value}s"
  end

  defp format_idle_timeout_ms(value) when is_integer(value) and value > 0 do
    "#{div(value, 1_000)}s"
  end

  defp format_idle_retries(value) when is_integer(value) and value >= 0 do
    "#{value} idle retry(s)"
  end

  defp reached_max_slices?(_slice_number, 0), do: false
  defp reached_max_slices?(slice_number, max_slices), do: slice_number >= max_slices

  defp reached_max_idle_retries?(_idle_timeouts, 0), do: true

  defp reached_max_idle_retries?(idle_timeouts, max_idle_retries),
    do: idle_timeouts > max_idle_retries

  defp git_head(base) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: base, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  @doc false
  def build_invocation(args, opts \\ []) do
    {parsed_opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          check: :boolean,
          continuous: :boolean,
          prompt_only: :boolean,
          write_prompt: :string,
          model: :string,
          profile: :string,
          sandbox: :string,
          output_last_message: :string,
          json: :boolean,
          full_auto: :boolean,
          danger_full_access: :boolean,
          skip_git_repo_check: :boolean,
          idle_timeout_seconds: :integer,
          max_idle_retries: :integer,
          max_slices: :integer,
          pause_seconds: :integer
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    base = Keyword.get(opts, :base, File.cwd!())
    summary = RobertoLoop.resume_summary(base)

    if Keyword.get(parsed_opts, :check, false) and not RobertoLoop.complete?(summary) do
      Mix.raise("Roberto loop is not ready: missing files or active issue")
    end

    prompt_opts =
      case Keyword.fetch(opts, :issue_output) do
        {:ok, issue_output} -> [issue_output: issue_output]
        :error -> []
      end

    %{
      argv: args,
      base: base,
      summary: summary,
      prompt: RobertoLoop.codex_prompt(base, prompt_opts),
      write_prompt: parsed_opts[:write_prompt],
      prompt_only?: Keyword.get(parsed_opts, :prompt_only, false),
      continuous?: Keyword.get(parsed_opts, :continuous, false),
      idle_timeout_seconds: default_idle_timeout_seconds(parsed_opts),
      max_idle_retries: default_max_idle_retries(parsed_opts),
      max_slices: default_max_slices(parsed_opts),
      pause_seconds: default_pause_seconds(parsed_opts),
      codex_opts: codex_opts(parsed_opts, base)
    }
  end

  defp maybe_write_prompt(_prompt, nil), do: :ok

  defp maybe_write_prompt(prompt, path) do
    File.write!(path, prompt)
    Mix.shell().info("Wrote Codex prompt: #{path}")
  end

  defp codex_opts(opts, base) do
    [
      cd: base,
      model: opts[:model],
      profile: opts[:profile],
      sandbox: opts[:sandbox],
      output_last_message: opts[:output_last_message],
      idle_timeout_ms: idle_timeout_ms(opts),
      json: opts[:json] || false,
      skip_git_repo_check: opts[:skip_git_repo_check] || false,
      full_auto: default_full_auto?(opts),
      danger_full_access: opts[:danger_full_access] || false
    ]
  end

  defp idle_timeout_ms(opts) do
    case default_idle_timeout_seconds(opts) do
      value when is_integer(value) and value > 0 -> value * 1_000
      _ -> 0
    end
  end

  defp default_full_auto?(opts) do
    if opts[:danger_full_access] do
      false
    else
      Keyword.get(opts, :full_auto, true)
    end
  end

  defp default_max_slices(opts) do
    case Keyword.get(opts, :max_slices, @default_max_slices) do
      value when is_integer(value) and value >= 0 -> value
      _ -> Mix.raise("--max-slices must be an integer >= 0")
    end
  end

  defp default_pause_seconds(opts) do
    case Keyword.get(opts, :pause_seconds, @default_pause_seconds) do
      value when is_integer(value) and value >= 0 -> value
      _ -> Mix.raise("--pause-seconds must be an integer >= 0")
    end
  end

  defp default_idle_timeout_seconds(opts) do
    if Keyword.get(opts, :continuous, false) do
      case Keyword.get(opts, :idle_timeout_seconds, @default_idle_timeout_seconds) do
        value when is_integer(value) and value >= 0 -> value
        _ -> Mix.raise("--idle-timeout-seconds must be an integer >= 0")
      end
    else
      case Keyword.get(opts, :idle_timeout_seconds, 0) do
        value when is_integer(value) and value >= 0 -> value
        _ -> Mix.raise("--idle-timeout-seconds must be an integer >= 0")
      end
    end
  end

  defp default_max_idle_retries(opts) do
    case Keyword.get(opts, :max_idle_retries, @default_max_idle_retries) do
      value when is_integer(value) and value >= 0 -> value
      _ -> Mix.raise("--max-idle-retries must be an integer >= 0")
    end
  end
end
