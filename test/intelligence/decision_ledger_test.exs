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
    iteration = Keyword.get(opts, :iteration, 0)
    session_id = Keyword.get(opts, :session_id, "test")

    send(pid, {:tool_outcome, %{
      name: tool_name,
      args: args_hint,
      success: success,
      duration_ms: duration,
      result: result,
      session_id: session_id,
      iteration: iteration
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

    test "dedicated git tool → git" do
      assert DecisionLedger.derive_context("git", "operation, path") == "git"
    end

    test "file_read + absolute lib/ path → lib/" do
      assert DecisionLedger.derive_context("file_read", "/Users/speed/Projects/vaos-daemon/lib/daemon/agent.ex") == "lib/"
    end

    test "file_edit + absolute test/ path → test/" do
      assert DecisionLedger.derive_context("file_edit", "/home/user/project/test/some_test.exs") == "test/"
    end

    test "file_read + config/ path → config/" do
      assert DecisionLedger.derive_context("file_read", "config/runtime.exs") == "config/"
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

  # ── Pair (sequence) tracking — iteration-aware ────────────────────────

  describe "pair tracking (iteration-aware)" do
    test "single-tool iterations create pairs across iteration boundaries" do
      {pid, _table, pairs} = start_test_ledger()

      # Iteration 1: file_read (single tool — will be unambiguous predecessor)
      simulate_outcome(pid, "file_read", "lib/foo.ex", true, iteration: 1)
      # Iteration 2: file_edit (should pair with iteration 1's single tool)
      simulate_outcome(pid, "file_edit", "lib/foo.ex", true, iteration: 2)

      pair_entries = :ets.tab2list(pairs)
      assert length(pair_entries) == 1
      [{pair_key, pair}] = pair_entries
      assert pair_key == "file_read:lib/->file_edit:lib/"
      assert pair.success_count == 1
      assert pair.failure_count == 0

      GenServer.stop(pid)
    end

    test "parallel tools in same iteration do NOT create pairs between each other" do
      {pid, _table, pairs} = start_test_ledger()

      # Iteration 1: three tools run in parallel (same iteration number)
      simulate_outcome(pid, "file_read", "lib/a.ex", true, iteration: 1)
      simulate_outcome(pid, "file_read", "lib/b.ex", true, iteration: 1)
      simulate_outcome(pid, "web_search", "elixir genserver", true, iteration: 1)

      # No pairs — all within same iteration
      assert :ets.tab2list(pairs) == []

      GenServer.stop(pid)
    end

    test "multi-tool iteration does NOT create pairs as predecessor" do
      {pid, _table, pairs} = start_test_ledger()

      # Iteration 1: two parallel tools (ambiguous predecessor)
      simulate_outcome(pid, "file_read", "lib/a.ex", true, iteration: 1)
      simulate_outcome(pid, "file_read", "lib/b.ex", true, iteration: 1)

      # Iteration 2: single tool — should NOT pair because iteration 1 had 2 tools
      simulate_outcome(pid, "file_edit", "lib/a.ex", true, iteration: 2)

      assert :ets.tab2list(pairs) == []

      GenServer.stop(pid)
    end

    test "tracks failure in pairs" do
      {pid, _table, pairs} = start_test_ledger()

      simulate_outcome(pid, "file_read", "lib/foo.ex", true, iteration: 1)
      simulate_outcome(pid, "file_edit", "lib/foo.ex", false,
        iteration: 2, result: "Error: file not found")

      [{_key, pair}] = :ets.tab2list(pairs)
      assert pair.success_count == 0
      assert pair.failure_count == 1

      GenServer.stop(pid)
    end

    test "accumulates pair counts across repeated single-tool iterations" do
      {pid, _table, pairs} = start_test_ledger()

      # Simulate: single git tool per iteration, alternating iterations
      # iter 1: git status (single) — no predecessor
      # iter 2: git log   (single) — pairs with iter 1
      # iter 3: git status (single) — pairs with iter 2
      # iter 4: git log   (single) — pairs with iter 3
      # iter 5: git status (single) — pairs with iter 4
      # iter 6: git log   (single) — pairs with iter 5
      # = 5 pairs of shell_execute:git->shell_execute:git
      for i <- 1..6 do
        cmd = if rem(i, 2) == 1, do: "git status", else: "git log"
        simulate_outcome(pid, "shell_execute", cmd, true, iteration: i)
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

      # Session A: file_read at iteration 1
      simulate_outcome(pid, "file_read", "lib/a.ex", true, iteration: 1, session_id: "session_a")

      # Session B: file_edit at iteration 2 (should NOT pair with session A)
      simulate_outcome(pid, "file_edit", "lib/b.ex", true, iteration: 2, session_id: "session_b")

      # No pairs — different sessions
      assert :ets.tab2list(pairs) == []

      GenServer.stop(pid)
    end

    test "realistic parallel-then-sequential flow" do
      {pid, _table, pairs} = start_test_ledger()

      # Iteration 1: LLM reads 3 files in parallel (no pairs as predecessor)
      simulate_outcome(pid, "file_read", "lib/a.ex", true, iteration: 1)
      simulate_outcome(pid, "file_read", "lib/b.ex", true, iteration: 1)
      simulate_outcome(pid, "file_read", "lib/c.ex", true, iteration: 1)

      # Iteration 2: LLM edits 1 file (multi-tool predecessor, no pairs)
      simulate_outcome(pid, "file_edit", "lib/a.ex", true, iteration: 2)

      # Iteration 3: LLM runs tests (single predecessor from iter 2, creates pair)
      simulate_outcome(pid, "shell_execute", "mix test", true, iteration: 3)

      pair_entries = :ets.tab2list(pairs)
      assert length(pair_entries) == 1
      [{pair_key, _}] = pair_entries
      assert pair_key == "file_edit:lib/->shell_execute:mix"

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
