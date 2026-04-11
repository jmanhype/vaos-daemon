defmodule Mix.Tasks.Osa.Roberto.Codex do
  @moduledoc """
  Launch a non-interactive Codex slice for the Roberto long-horizon program.

  Usage:

      mix osa.roberto.codex
      mix osa.roberto.codex --prompt-only
      mix osa.roberto.codex --write-prompt /tmp/roberto-prompt.md
      mix osa.roberto.codex --model gpt-5-codex --output-last-message /tmp/roberto-last.md
  """

  use Mix.Task

  alias Daemon.Codex.CLI
  alias Daemon.Operations.RobertoLoop

  @shortdoc "Launch Codex against the current Roberto program state"

  @impl true
  def run(args) do
    %{summary: summary, prompt: prompt} = invocation = build_invocation(args)

    maybe_write_prompt(prompt, invocation.write_prompt)

    if invocation.prompt_only? do
      Mix.shell().info(prompt)
      System.halt(0)
    end

    Mix.shell().info("Launching Codex for Roberto issue #{summary.current_issue}")
    Mix.shell().info("Latest trace: #{summary.latest_trace}")
    Mix.shell().info("Next step: #{summary.next_roberto_step}")
    Mix.shell().info("")

    case CLI.run_exec(prompt, invocation.codex_opts) do
      {:ok, 0} ->
        System.halt(0)

      {:ok, code} ->
        Mix.shell().error("Codex exited with code #{code}")
        System.halt(code)

      {:error, reason} ->
        Mix.raise("Failed to launch Codex: #{reason}")
    end
  end

  @doc false
  def build_invocation(args, opts \\ []) do
    {parsed_opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          check: :boolean,
          prompt_only: :boolean,
          write_prompt: :string,
          model: :string,
          profile: :string,
          sandbox: :string,
          output_last_message: :string,
          json: :boolean,
          full_auto: :boolean,
          danger_full_access: :boolean,
          skip_git_repo_check: :boolean
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
      summary: summary,
      prompt: RobertoLoop.codex_prompt(base, prompt_opts),
      write_prompt: parsed_opts[:write_prompt],
      prompt_only?: Keyword.get(parsed_opts, :prompt_only, false),
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
      json: opts[:json] || false,
      skip_git_repo_check: opts[:skip_git_repo_check] || false,
      full_auto: default_full_auto?(opts),
      danger_full_access: opts[:danger_full_access] || false
    ]
  end

  defp default_full_auto?(opts) do
    if opts[:danger_full_access] do
      false
    else
      Keyword.get(opts, :full_auto, true)
    end
  end
end
