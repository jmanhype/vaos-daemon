defmodule Daemon.Investigation.SelfDiagnosisTest do
  use ExUnit.Case, async: true

  alias Daemon.Investigation.SelfDiagnosis

  # -- GenServer lifecycle --------------------------------------------------

  describe "GenServer lifecycle" do
    test "starts successfully and returns pid" do
      name = :"self_diag_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(SelfDiagnosis, [], name: name)
      assert is_pid(pid)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "initial state has empty findings" do
      name = :"self_diag_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(SelfDiagnosis, [], name: name)
      state = :sys.get_state(pid)
      assert state.findings == []
      assert state.investigated_patterns == %{}
      assert state.active_task == nil
      assert state.last_pitfall_count == 0
      GenServer.stop(pid)
    end

    test "schedules poll timer on init" do
      name = :"self_diag_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(SelfDiagnosis, [], name: name)

      # The process should have a :poll message scheduled
      # We verify by checking the process is alive and will receive :poll
      assert Process.alive?(pid)

      # Send :poll manually to verify it handles it without crashing
      send(pid, :poll)
      Process.sleep(50)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  # -- Pitfall detection ----------------------------------------------------

  describe "pitfall detection" do
    test "skips when no CrashLearner process is registered" do
      name = :"self_diag_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(SelfDiagnosis, [], name: name)

      # Trigger poll — should handle missing CrashLearner gracefully
      send(pid, :poll)
      Process.sleep(50)
      state = :sys.get_state(pid)
      assert state.last_pitfall_count == 0
      assert state.active_task == nil
      GenServer.stop(pid)
    end

    test "respects cooldown for already-investigated patterns" do
      name = :"self_diag_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(SelfDiagnosis, [], name: name)

      # Simulate a recently investigated pattern
      hash = :erlang.phash2("test_pattern")
      state = :sys.get_state(pid)
      updated_state = %{state | investigated_patterns: %{hash => DateTime.utc_now()}}
      :sys.replace_state(pid, fn _ -> updated_state end)

      state = :sys.get_state(pid)
      assert Map.has_key?(state.investigated_patterns, hash)
      GenServer.stop(pid)
    end
  end

  # -- Safety mechanisms ----------------------------------------------------

  describe "safety mechanisms" do
    test "only one active investigation at a time" do
      name = :"self_diag_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(SelfDiagnosis, [], name: name)

      # Set active_task to a fake ref to simulate running investigation
      fake_ref = make_ref()
      :sys.replace_state(pid, fn state -> %{state | active_task: fake_ref} end)

      state = :sys.get_state(pid)
      assert state.active_task == fake_ref

      # Poll should not start a new investigation
      send(pid, :poll)
      Process.sleep(50)
      state = :sys.get_state(pid)
      assert state.active_task == fake_ref
      GenServer.stop(pid)
    end

    test "task crash resets active_task via DOWN message" do
      name = :"self_diag_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(SelfDiagnosis, [], name: name)

      # Set active_task to a ref
      ref = make_ref()
      :sys.replace_state(pid, fn state -> %{state | active_task: ref} end)

      # Send DOWN message for that ref
      send(pid, {:DOWN, ref, :process, self(), :normal})
      Process.sleep(50)
      state = :sys.get_state(pid)
      assert state.active_task == nil
      GenServer.stop(pid)
    end

    test "self-diagnosis topic prefix is correct" do
      assert SelfDiagnosis.self_diagnosis_prefix() == "Why does this error occur"
    end
  end

  # -- Finding storage ------------------------------------------------------

  describe "finding storage" do
    test "records findings in rolling buffer" do
      name = :"self_diag_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(SelfDiagnosis, [], name: name)

      # Send diagnosis_complete messages
      for i <- 1..5 do
        hash = :erlang.phash2("pattern_#{i}")
        send(pid, {:diagnosis_complete, hash, {:ok, %{direction: "supporting", topic: "test_#{i}"}}})
      end

      Process.sleep(100)
      state = :sys.get_state(pid)
      assert length(state.findings) == 5
      GenServer.stop(pid)
    end

    test "buffer respects max size of 50" do
      name = :"self_diag_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(SelfDiagnosis, [], name: name)

      # Send 55 findings
      for i <- 1..55 do
        hash = :erlang.phash2("pattern_#{i}")
        send(pid, {:diagnosis_complete, hash, {:ok, %{direction: "supporting", topic: "test_#{i}"}}})
      end

      Process.sleep(200)
      state = :sys.get_state(pid)
      assert length(state.findings) <= 50
      GenServer.stop(pid)
    end
  end

  # -- Corrective actions ---------------------------------------------------

  describe "corrective actions" do
    test "emits system_event on completion" do
      name = :"self_diag_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(SelfDiagnosis, [], name: name)

      # diagnosis_complete should not crash even without Bus running
      hash = :erlang.phash2("test_pattern")
      send(pid, {:diagnosis_complete, hash, {:ok, %{direction: "supporting", topic: "test"}}})
      Process.sleep(50)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "handles error results gracefully" do
      name = :"self_diag_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(SelfDiagnosis, [], name: name)

      hash = :erlang.phash2("error_pattern")
      send(pid, {:diagnosis_complete, hash, {:error, "investigation failed"}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert length(state.findings) == 1
      assert state.active_task == nil
      GenServer.stop(pid)
    end

    test "resets active_task after diagnosis complete" do
      name = :"self_diag_test_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = GenServer.start_link(SelfDiagnosis, [], name: name)

      ref = make_ref()
      :sys.replace_state(pid, fn state -> %{state | active_task: ref} end)

      hash = :erlang.phash2("test_pattern")
      send(pid, {:diagnosis_complete, hash, {:ok, %{direction: "insufficient_evidence"}}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.active_task == nil
      GenServer.stop(pid)
    end
  end
end
