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

  test "run_exec returns an idle timeout when codex stops emitting output" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "codex-cli-timeout-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    codex_path = Path.join(tmp_dir, "codex")

    File.write!(
      codex_path,
      """
      #!/bin/sh
      sleep 5
      """
    )

    File.chmod!(codex_path, 0o755)

    original_path = System.get_env("PATH", "")
    System.put_env("PATH", "#{tmp_dir}:#{original_path}")

    on_exit(fn ->
      System.put_env("PATH", original_path)
    end)

    assert {:idle_timeout, 50} =
             CLI.run_exec("resume roberto", cd: tmp_dir, idle_timeout_ms: 50)
  end
end
