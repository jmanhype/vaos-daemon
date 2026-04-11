defmodule Mix.Tasks.Osa.Roberto.CodexTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Osa.Roberto.Codex

  test "build_invocation supports prompt-only without explicit check flag" do
    base =
      System.tmp_dir!() |> Path.join("roberto-codex-task-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "docs/operations/roberto-content"))

    for file <- ~w(SPEC.md PLAN.md IMPLEMENT.md STATUS.md) do
      File.write!(Path.join(base, file), "# #{file}\n")
    end

    File.write!(
      Path.join(base, "STATUS.md"),
      """
      # STATUS

      **Canonical status**: [docs/operations/roberto-content/Documentation.md](docs/operations/roberto-content/Documentation.md)
      **Epic**: `vas-swarm-jji`
      **Current active issue**: `vas-swarm-1a6`
      **Latest trace**: [trace](#{base}/trace.json)
      **Next Roberto step**: Launch the Codex slice from the shell wrapper.
      """
    )

    for file <- ~w(Prompt.md Plan.md Implement.md Documentation.md) do
      File.write!(Path.join(base, "docs/operations/roberto-content/#{file}"), "# #{file}\n")
    end

    invocation =
      Codex.build_invocation(["--prompt-only"],
        base: base,
        issue_output: "vas-swarm-1a6: add codex runner"
      )

    assert invocation.prompt_only?
    assert invocation.summary.current_issue == "vas-swarm-1a6"
    assert invocation.codex_opts[:cd] == base
    assert invocation.prompt =~ "Current active issue: vas-swarm-1a6"
    assert invocation.prompt =~ "vas-swarm-1a6: add codex runner"
  end

  test "build_invocation parses continuous loop controls" do
    base =
      System.tmp_dir!()
      |> Path.join("roberto-codex-continuous-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "docs/operations/roberto-content"))

    for file <- ~w(SPEC.md PLAN.md IMPLEMENT.md STATUS.md) do
      File.write!(Path.join(base, file), "# #{file}\n")
    end

    File.write!(
      Path.join(base, "STATUS.md"),
      """
      # STATUS

      **Canonical status**: [docs/operations/roberto-content/Documentation.md](docs/operations/roberto-content/Documentation.md)
      **Epic**: `vas-swarm-jji`
      **Current active issue**: `vas-swarm-zmw`
      **Latest trace**: [trace](#{base}/trace.json)
      **Next Roberto step**: Keep cycling until blocked.
      """
    )

    for file <- ~w(Prompt.md Plan.md Implement.md Documentation.md) do
      File.write!(Path.join(base, "docs/operations/roberto-content/#{file}"), "# #{file}\n")
    end

    invocation =
      Codex.build_invocation(
        ["--continuous", "--max-slices", "3", "--pause-seconds", "0"],
        base: base,
        issue_output: "vas-swarm-zmw: add autonomous continuous runner"
      )

    assert invocation.continuous?
    assert invocation.max_slices == 3
    assert invocation.pause_seconds == 0
    assert invocation.summary.current_issue == "vas-swarm-zmw"
  end

  test "progress_made? detects head and issue movement" do
    before = %{
      head: "aaa",
      summary: %{
        current_issue: "vas-swarm-jji.3",
        latest_trace: "/tmp/trace-1.json",
        next_roberto_step: "Close jji.3"
      }
    }

    same = before

    advanced_issue = %{
      head: "bbb",
      summary: %{
        current_issue: "vas-swarm-jji.4",
        latest_trace: "/tmp/trace-2.json",
        next_roberto_step: "Start jji.4"
      }
    }

    same_issue_new_commit = %{
      head: "ccc",
      summary: %{
        current_issue: "vas-swarm-jji.3",
        latest_trace: "/tmp/trace-3.json",
        next_roberto_step: "Continue jji.3"
      }
    }

    refute Codex.progress_made?(before, same)
    assert Codex.progress_made?(before, advanced_issue)
    assert Codex.progress_made?(before, same_issue_new_commit)
  end
end
