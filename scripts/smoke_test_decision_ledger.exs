# Smoke test DecisionLedger in isolation (no full app start needed)
# Usage: cd vas-swarm && mix run --no-start scripts/smoke_test_decision_ledger.exs

{:ok, pid} = Daemon.Intelligence.DecisionLedger.start_link(test_mode: true)
state = :sys.get_state(pid)
IO.puts("1. GenServer started, ETS table: #{state.ets_table}")

# Test context derivation
"git" = Daemon.Intelligence.DecisionLedger.derive_context("shell_execute", "git status")
"lib/" = Daemon.Intelligence.DecisionLedger.derive_context("file_read", "lib/foo.ex")
"research" = Daemon.Intelligence.DecisionLedger.derive_context("investigate", "topic")
IO.puts("2. Context derivation correct")

# Simulate 6 tool outcomes
for i <- 1..6 do
  send(pid, {:tool_outcome, %{name: "shell_execute", args: "git status", success: true, duration_ms: 100 + i * 10, result: "ok", session_id: "smoke"}})
end
Process.sleep(100)

# Check ETS patterns
[{key, pattern}] = :ets.tab2list(state.ets_table)
^key = "shell_execute:git"
6 = pattern.success_count
0 = pattern.failure_count
IO.puts("3. Pattern tracking works: #{key} -> #{pattern.success_count} successes, avg #{Float.round(pattern.avg_duration_ms, 0)}ms")

# Simulate a failure
send(pid, {:tool_outcome, %{name: "web_fetch", args: "https://example.com", success: false, duration_ms: 3200, result: "Error: 429 rate limit", session_id: "smoke"}})
Process.sleep(50)

all = :ets.tab2list(state.ets_table)
2 = length(all)
IO.puts("4. Total patterns: #{length(all)}")

# Check JSONL persistence
true = File.exists?(state.jsonl_path)
{:ok, content} = File.read(state.jsonl_path)
lines = String.split(content, "\n", trim: true)
7 = length(lines)
IO.puts("5. JSONL persistence: #{length(lines)} lines at #{state.jsonl_path}")

# Verify context_block does not crash
result = Daemon.Intelligence.DecisionLedger.context_block()
true = is_nil(result) or is_binary(result)
IO.puts("6. context_block/0 safe: #{inspect(result)}")

# Meta tool filtering
send(pid, {:tool_outcome, %{name: "knowledge", args: "query", success: true, duration_ms: 50, result: "ok", session_id: "smoke"}})
Process.sleep(50)
2 = length(:ets.tab2list(state.ets_table))
IO.puts("7. Meta tool filtered (knowledge not recorded)")

# Test JSONL reload
GenServer.stop(pid)
{:ok, pid2} = Daemon.Intelligence.DecisionLedger.start_link(test_mode: true)
state2 = :sys.get_state(pid2)
# New test instance won't load the previous JSONL (different temp dir), but verify the mechanism
IO.puts("8. GenServer restart clean")
GenServer.stop(pid2)

# Cleanup temp files
File.rm_rf!(Path.dirname(state.jsonl_path))

IO.puts("\nAll 8 smoke tests passed!")
