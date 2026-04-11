defmodule Daemon.Intelligence.RuntimeLedgerIsolationTest do
  use ExUnit.Case, async: false

  alias Daemon.Intelligence.{DecisionJournal, DecisionLedger}
  alias Vaos.Ledger.Epistemic.Ledger, as: EpistemicLedger

  @journal_path Path.expand("~/.daemon/intelligence/decision_journal.json")

  setup do
    unique_id = System.unique_integer([:positive])
    runtime_name = :"decision_runtime_ledger_test_#{unique_id}"
    runtime_path = Path.join(System.tmp_dir!(), "decision_runtime_ledger_#{unique_id}.json")
    investigate_path = Path.join(System.tmp_dir!(), "investigate_ledger_#{unique_id}.json")

    original_runtime_env = Application.get_env(:daemon, :decision_runtime_ledger)

    Application.put_env(
      :daemon,
      :decision_runtime_ledger,
      name: runtime_name,
      path: runtime_path
    )

    original_journal =
      case File.read(@journal_path) do
        {:ok, content} -> {:present, content}
        {:error, _} -> :missing
      end

    {:ok, _pid} = EpistemicLedger.start_link(path: investigate_path, name: :investigate_ledger)

    on_exit(fn ->
      restore_runtime_env(original_runtime_env)
      restore_journal(original_journal)
      stop_named_process(runtime_name)
      stop_named_process(:investigate_ledger)
      File.rm(runtime_path)
      File.rm(investigate_path)
    end)

    {:ok, runtime_name: runtime_name}
  end

  test "decision telemetry writes stay off the investigate ledger", %{runtime_name: runtime_name} do
    {:ok, pid} = DecisionLedger.start_link(test_mode: true, runtime_ledger: true)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)

    for _ <- 1..5 do
      simulate_outcome(pid, "shell_execute", "git status", true)
    end

    assert {:ok, journal_state} = DecisionJournal.init([])

    branch = "runtime-ledger-isolation-#{System.unique_integer([:positive])}"

    {:reply, :approved, journal_state} =
      DecisionJournal.handle_call(
        {:propose, :investigation, :investigate,
         %{topic: "runtime ledger isolation", branch: branch}},
        self(),
        journal_state
      )

    {:reply, :ok, _journal_state} =
      DecisionJournal.handle_call(
        {:record_outcome, branch, :success, %{topic: "runtime ledger isolation"}},
        self(),
        journal_state
      )

    assert [] == EpistemicLedger.list_claims(:investigate_ledger)

    assert is_pid(Process.whereis(runtime_name))

    runtime_claims = EpistemicLedger.list_claims(runtime_name)

    assert Enum.any?(runtime_claims, fn claim -> "decision_ledger" in claim.tags end)
    assert Enum.any?(runtime_claims, fn claim -> "decision_journal" in claim.tags end)
  end

  defp simulate_outcome(pid, tool_name, args_hint, success, opts \\ []) do
    duration = Keyword.get(opts, :duration_ms, 100)
    result = Keyword.get(opts, :result, if(success, do: "ok", else: "Error: something failed"))
    iteration = Keyword.get(opts, :iteration, 0)
    session_id = Keyword.get(opts, :session_id, "test")

    send(
      pid,
      {:tool_outcome,
       %{
         name: tool_name,
         args: args_hint,
         success: success,
         duration_ms: duration,
         result: result,
         session_id: session_id,
         iteration: iteration
       }}
    )

    :sys.get_state(pid)
  end

  defp restore_runtime_env(nil), do: Application.delete_env(:daemon, :decision_runtime_ledger)
  defp restore_runtime_env(value), do: Application.put_env(:daemon, :decision_runtime_ledger, value)

  defp restore_journal({:present, content}) do
    File.mkdir_p!(Path.dirname(@journal_path))
    File.write!(@journal_path, content)
  end

  defp restore_journal(:missing), do: File.rm(@journal_path)

  defp stop_named_process(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      _ -> :ok
    end
  end
end
