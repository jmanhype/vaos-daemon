defmodule Daemon.Codex.CLITest do
  use ExUnit.Case, async: true

  alias Daemon.Codex.CLI

  test "exec_args builds a full-auto codex exec invocation by default" do
    args = CLI.exec_args("investigate the next bottleneck", cd: "/tmp/roberto")

    assert args == [
             "exec",
             "--cd",
             "/tmp/roberto",
             "--full-auto",
             "investigate the next bottleneck"
           ]
  end

  test "exec_args forwards optional flags and danger mode" do
    args =
      CLI.exec_args("resume roberto",
        cd: "/tmp/roberto",
        model: "gpt-5-codex",
        profile: "default",
        sandbox: "danger-full-access",
        output_last_message: "/tmp/roberto-last.md",
        json: true,
        skip_git_repo_check: true,
        danger_full_access: true
      )

    assert args == [
             "exec",
             "--cd",
             "/tmp/roberto",
             "--model",
             "gpt-5-codex",
             "--profile",
             "default",
             "--sandbox",
             "danger-full-access",
             "--output-last-message",
             "/tmp/roberto-last.md",
             "--json",
             "--skip-git-repo-check",
             "--dangerously-bypass-approvals-and-sandbox",
             "resume roberto"
           ]
  end
end
