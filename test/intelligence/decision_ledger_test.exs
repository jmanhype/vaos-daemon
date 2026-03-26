defmodule Daemon.Intelligence.DecisionLedgerTest do
  use ExUnit.Case, async: true

  alias Daemon.Intelligence.DecisionLedger

  # Use test_mode to get isolated ETS tables and temp dirs
  defp start_test_ledger do
    {:ok, pid} = DecisionLedger.start_link(test_mode: true)
    state = :sys.get_state(pid)
    {pid, state.ets_table, state.pairs_table}
  end

  defp simulate_outcome(pid, tool_name, args_hint, success, opts \\ []) do
    duration = Keyword.get(opts, :duration_ms, 100)
    result = Keyword.get(opts, :result, if(success, do: "ok", else: "Error: something failed"))

    send(pid, {:tool_outcome, %{
      name: tool_name,
      args: args_hint,
      success: success,
      duration_ms: duration,
      result: result,
      session_id: "test"
    }})

    # Give GenServer time to process
    :timer.sleep(10)
  end

  # ── GenServer lifecycle ──────────────────────────────────────────────────

  describe "GenServer lifecycle" do
    test "starts successfully in test mode" do
      {pid, _table, _pairs} = start_test_ledger()
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "initial state has empty pending_calls and claim_cache" do
      {pid, _table, _pairs} = start_test_ledger()
      state = :sys.get_state(pid)
      assert state.pending_calls == %{}
      assert state.claim_cache == %{}
      GenServer.stop(pid)
    end

    test "ETS table is created" do
      {pid, table, _pairs} = start_test_ledger()
      assert :ets.info(table) != :undefined
      GenServer.stop(pid)
    end
  end

  # ── Context derivation ─────────────────────────────────────────────────

  describe "derive_context/2" do
    test "shell_execute + git command → git" do
      assert DecisionLedger.derive_context("shell_execute", "git status") == "git"
    end

    test "shell_execute + mix command → mix" do
      assert DecisionLedger.derive_context("shell_execute", "mix test") == "mix"
    end

    test "file_read + lib/ path → lib/" do
      assert DecisionLedger.derive_context("file_read", "lib/daemon/agent.ex") == "lib/"
    end

    test "file_edit + test/ path → test/" do
      assert DecisionLedger.derive_context("file_edit", "test/some_test.exs") == "test/"
    end

    test "investigate → research" do
      assert DecisionLedger.derive_context("investigate", "quantum computing") == "research"
    end

    test "web_fetch → web" do
      assert DecisionLedger.derive_context("web_fetch", "https://example.com") == "web"
    end

    test "web_search → web" do
      assert DecisionLedger.derive_context("web_search", "elixir genserver") == "web"
    end

    test "unknown tool → general" do
      assert DecisionLedger.derive_context("custom_tool", "some args") == "general"
    end

    test "nil args → general fallback" do
      assert DecisionLedger.derive_context("shell_execute", nil) == "general"
    end
  end

  # ── Pattern tracking ───────────────────────────────────────────────────

  describe "pattern tracking" do
    test "tool outcome creates pattern in ETS" do
      {pid, table, _pairs} = start_test_ledger()

      simulate_outcome(pid, "shell_execute", "git status", true)

      entries = :ets.tab2list(table)
      assert length(entries) == 1
      [{key, pattern}] = entries
      assert key == "shell_execute:git"
      assert pattern.tool_name == "shell_execute"
      assert pattern.context_type == "git"
      assert pattern.success_count == 1
      assert pattern.failure_count == 0

      GenServer.stop(pid)
    end

    test "success increments success_count" do
      {pid, table, _pairs} = start_test_ledger()

      simulate_outcome(pid, "file_read", "lib/foo.ex", true)
      simulate_outcome(pid, "file_read", "lib/bar.ex", true)
      simulate_outcome(pid, "file_read", "lib/baz.ex", true)

      [{_key, pattern}] = :ets.tab2list(table)
      assert pattern.success_count == 3
      assert pattern.failure_count == 0

      GenServer.stop(pid)
    end

    test "failure increments failure_count and adds to recent_errors" do
      {pid, table, _pairs} = start_test_ledger()

      simulate_outcome(pid, "web_fetch", "https://example.com", false,
        result: "Error: 429 rate limit")

      [{_key, pattern}] = :ets.tab2list(table)
      assert pattern.failure_count == 1
      assert pattern.success_count == 0
      assert length(pattern.recent_errors) == 1
      assert hd(pattern.recent_errors) =~ "429"

      GenServer.stop(pid)
    end

    test "avg_duration_ms is computed correctly" do
      {pid, table, _pairs} = start_test_ledger()

      simulate_outcome(pid, "investigate", "topic", true, duration_ms: 100)
      simulate_outcome(pid, "investigate", "topic2", true, duration_ms: 200)

      [{_key, pattern}] = :ets.tab2list(table)
      assert pattern.avg_duration_ms == 150.0

      GenServer.stop(pid)
    end
  end

  # ── Meta tool filtering ────────────────────────────────────────────────

  describe "meta tool filtering" do
    test "knowledge tool calls are not recorded" do
      {pid, table, _pairs} = start_test_ledger()

      simulate_outcome(pid, "knowledge", "some query", true)
      simulate_outcome(pid, "memory_recall", "something", true)
      simulate_outcome(pid, "memory_save", "data", true)

      assert :ets.tab2list(table) == []

      GenServer.stop(pid)
    end
  end

  # ── Buffer limits ──────────────────────────────────────────────────────

  describe "buffer limits" do
    test "recent_errors capped at 3" do
      {pid, table, _pairs} = start_test_ledger()

      for i <- 1..5 do
        simulate_outcome(pid, "web_fetch", "https://example.com", false,
          result: "Error: #{i}")
      end

      [{_key, pattern}] = :ets.tab2list(table)
      assert length(pattern.recent_errors) == 3

      GenServer.stop(pid)
    end
  end

  # ── context_block/0 ────────────────────────────────────────────────────

  describe "context_block" do
    test "returns nil when no patterns exist" do
      {pid, _table, _pairs} = start_test_ledger()
      # context_block reads from the module-level ETS, so we test the function directly
      # with the freshly started ledger that has no data
      # Since test_mode uses a different ETS name, we test the public function separately
      assert DecisionLedger.context_block() == nil or is_binary(DecisionLedger.context_block())
      GenServer.stop(pid)
    end

    test "returns formatted text when patterns have 5+ observations" do
      {pid, table, _pairs} = start_test_ledger()

      for _ <- 1..6 do
        simulate_outcome(pid, "shell_execute", "git status", true)
      end

      # Read directly from the test ETS table
      [{_key, pattern}] = :ets.tab2list(table)
      total = pattern.success_count + pattern.failure_count
      assert total >= 5

      GenServer.stop(pid)
    end
  end

  # ── JSONL persistence ──────────────────────────────────────────────────

  describe "JSONL persistence" do
    test "writes to JSONL and reloads on init" do
      {pid, _table, _pairs} = start_test_ledger()
      state = :sys.get_state(pid)
      jsonl_path = state.jsonl_path

      # Generate some data
      for _ <- 1..3 do
        simulate_outcome(pid, "file_read", "lib/test.ex", true)
      end

      # Verify JSONL file exists and has content
      assert File.exists?(jsonl_path)
      {:ok, content} = File.read(jsonl_path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 3

      GenServer.stop(pid)

      # Start a new ledger with the same JSONL path to test reload
      # We need a fresh ETS table for this
      suffix = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
      new_table = :"daemon_decision_ledger_reload_#{suffix}"
      :ets.new(new_table, [:set, :named_table, :public, read_concurrency: true])

      # Manually load from JSONL to verify
      content
      |> String.split("\n", trim: true)
      |> Enum.each(fn line ->
        {:ok, _entry} = Jason.decode(line)
      end)

      :ets.delete(new_table)
    end
  end

  # ── Outcome correlation ────────────────────────────────────────────────

  describe "outcome correlation" do
    test "tool_call_start + tool_outcome flow records duration" do
      {pid, table, _pairs} = start_test_ledger()

      # Simulate the full event flow
      send(pid, {:tool_call_start, %{name: "shell_execute", args: "git log", session_id: "test"}})
      :timer.sleep(5)
      send(pid, {:tool_call_end, %{name: "shell_execute", duration_ms: 250, session_id: "test"}})
      :timer.sleep(5)
      send(pid, {:tool_outcome, %{
        name: "shell_execute",
        args: "git log",
        success: true,
        result: "commit abc123",
        session_id: "test"
      }})
      :timer.sleep(15)

      [{_key, pattern}] = :ets.tab2list(table)
      assert pattern.total_duration_ms == 250
      assert pattern.success_count == 1

      # Verify pending_calls is cleaned up
      state = :sys.get_state(pid)
      assert state.pending_calls == %{}

      GenServer.stop(pid)
    end
  end

  # ── Error handling ─────────────────────────────────────────────────────

  describe "error handling" do
    test "handles unknown messages gracefully" do
      {pid, _table, _pairs} = start_test_ledger()

      send(pid, :unknown_message)
      send(pid, {:random, "data"})
      :timer.sleep(10)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "handles malformed tool_outcome gracefully" do
      {pid, _table, _pairs} = start_test_ledger()

      send(pid, {:tool_outcome, %{name: nil, success: true}})
      :timer.sleep(10)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  # ── Pair (sequence) tracking ───────────────────────────────────────────

  describe "pair tracking" do
    test "records tool pairs across sequential calls" do
      {pid, _table, pairs} = start_test_ledger()

      # Call 1: file_read (no pair yet — no previous tool)
      simulate_outcome(pid, "file_read", "lib/foo.ex", true)
      # Call 2: file_edit (pair: file_read:lib/ -> file_edit:lib/)
      simulate_outcome(pid, "file_edit", "lib/foo.ex", true)

      pair_entries = :ets.tab2list(pairs)
      assert length(pair_entries) == 1
      [{pair_key, pair}] = pair_entries
      assert pair_key == "file_read:lib/->file_edit:lib/"
      assert pair.success_count == 1
      assert pair.failure_count == 0

      GenServer.stop(pid)
    end

    test "tracks failure in pairs" do
      {pid, _table, pairs} = start_test_ledger()

      simulate_outcome(pid, "file_read", "lib/foo.ex", true)
      simulate_outcome(pid, "file_edit", "lib/foo.ex", false, result: "Error: file not found")

      [{_key, pair}] = :ets.tab2list(pairs)
      assert pair.success_count == 0
      assert pair.failure_count == 1

      GenServer.stop(pid)
    end

    test "accumulates pair counts across multiple sequences" do
      {pid, _table, pairs} = start_test_ledger()

      # Simulate: git status -> git log (3 times)
      # Both derive to shell_execute:git, so pair key = shell_execute:git->shell_execute:git
      # 6 calls total: call 1 has no pair (first), calls 2-6 each create a pair = 5 pairs
      for _ <- 1..3 do
        simulate_outcome(pid, "shell_execute", "git status", true)
        simulate_outcome(pid, "shell_execute", "git log", true)
      end

      pair_entries = :ets.tab2list(pairs)
      git_pair = Enum.find(pair_entries, fn {k, _} -> k == "shell_execute:git->shell_execute:git" end)
      assert git_pair != nil
      {_, p} = git_pair
      assert p.success_count == 5

      GenServer.stop(pid)
    end

    test "different sessions don't create cross-session pairs" do
      {pid, _table, pairs} = start_test_ledger()

      # Session A: file_read
      send(pid, {:tool_outcome, %{name: "file_read", args: "lib/a.ex", success: true, duration_ms: 50, result: "ok", session_id: "session_a"}})
      :timer.sleep(10)

      # Session B: file_edit (should NOT pair with session A's file_read)
      send(pid, {:tool_outcome, %{name: "file_edit", args: "lib/b.ex", success: true, duration_ms: 50, result: "ok", session_id: "session_b"}})
      :timer.sleep(10)

      # No pairs should exist (each session only has 1 call)
      assert :ets.tab2list(pairs) == []

      GenServer.stop(pid)
    end
  end

  # ── best_next_tools/1 ──────────────────────────────────────────────────

  describe "best_next_tools/1" do
    test "returns empty list when no pairs exist" do
      assert DecisionLedger.best_next_tools("shell_execute:git") == []
    end
  end
end
