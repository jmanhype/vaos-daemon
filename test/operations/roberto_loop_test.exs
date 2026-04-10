defmodule Daemon.Operations.RobertoLoopTest do
  use ExUnit.Case, async: true

  alias Daemon.Operations.RobertoLoop

  test "resume_summary parses root status entrypoints" do
    base = System.tmp_dir!() |> Path.join("roberto-loop-#{System.unique_integer([:positive])}")

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
      **Current active issue**: `vas-swarm-942`
      **Latest trace**: [trace](#{base}/trace.json)
      **Next Roberto step**: Preserve direct-trial corpus quality.

      ## Resume

      1. Read this file.
      2. Open `vas-swarm-942`.
      """
    )

    for file <- ~w(Prompt.md Plan.md Implement.md Documentation.md) do
      File.write!(
        Path.join(base, "docs/operations/roberto-content/#{file}"),
        "# #{file}\n"
      )
    end

    summary = RobertoLoop.resume_summary(base)

    assert summary.epic_id == "vas-swarm-jji"
    assert summary.current_issue == "vas-swarm-942"
    assert summary.next_roberto_step == "Preserve direct-trial corpus quality."
    assert summary.resume_steps == ["1. Read this file.", "2. Open `vas-swarm-942`."]
    assert summary.missing_files == []
    assert RobertoLoop.complete?(summary)
  end

  test "resume_summary reports missing control files" do
    base = System.tmp_dir!() |> Path.join("roberto-loop-missing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    File.write!(Path.join(base, "STATUS.md"), "# STATUS\n")

    summary = RobertoLoop.resume_summary(base)

    assert summary.missing_files != []
    refute RobertoLoop.complete?(summary)
  end
end
