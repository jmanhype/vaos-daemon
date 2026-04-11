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
end
