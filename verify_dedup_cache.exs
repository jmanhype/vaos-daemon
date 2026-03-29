#!/usr/bin/env elixir

# Verification script for DedupCache integration
# This script verifies that:
# 1. The DedupCache module exists and compiles
# 2. The ETS table is created on startup
# 3. Basic cache operations work

IO.puts "=== DedupCache Integration Verification ===\n"

# Check if the module compiles
IO.puts "1. Checking if DedupCache module compiles..."
Code.append_path("_build/dev/lib/daemon/ebin")

case Code.ensure_loaded(Daemon.Channels.HTTP.DedupCache) do
  {:module, _} ->
    IO.puts "   ✓ DedupCache module loaded successfully"

  {:error, reason} ->
    IO.puts "   ✗ Failed to load DedupCache: #{inspect(reason)}"
    System.halt(1)
end

# Start the application infrastructure
IO.puts "\n2. Starting DedupCache GenServer..."
case Daemon.Channels.HTTP.DedupCache.start_link([]) do
  {:ok, pid} ->
    IO.puts "   ✓ DedupCache started: #{inspect(pid)}"

  {:error, {:already_started, pid}} ->
    IO.puts "   ✓ DedupCache already running: #{inspect(pid)}"

  {:error, reason} ->
    IO.puts "   ✗ Failed to start DedupCache: #{inspect(reason)}"
    System.halt(1)
end

# Check if ETS table exists
IO.puts "\n3. Checking if ETS table exists..."
case :ets.whereis(:daemon_dedup_cache) do
  :undefined ->
    IO.puts "   ✗ ETS table :daemon_dedup_cache not found"
    System.halt(1)

  tid ->
    IO.puts "   ✓ ETS table exists: #{inspect(tid)}"

    # Check table info
    info = :ets.info(tid)
    IO.puts "     - Type: #{info[:type]}"
    IO.puts "     - Size: #{info[:size]} entries"
    IO.puts "     - Named table: #{info[:named_table]}"
end

# Test basic operations
IO.puts "\n4. Testing basic cache operations..."

# Test put and get
DedupCache.put_raw("test_key", %{status: 200, body: "test", headers: []}, 5_000)

case DedupCache.get_raw("test_key") do
  {:ok, response} ->
    IO.puts "   ✓ Put/Get successful"
    IO.puts "     - Status: #{response.status}"
    IO.puts "     - Body: #{response.body}"

  :miss ->
    IO.puts "   ✗ Put/Get failed: got :miss"
    System.halt(1)

  {:miss, :expired} ->
    IO.puts "   ✗ Put/Get failed: entry expired immediately"
    System.halt(1)
end

# Test statistics
IO.puts "\n5. Testing statistics..."
case DedupCache.stats() do
  {:ok, stats} ->
    IO.puts "   ✓ Statistics retrieved"
    IO.puts "     - Hits: #{stats.hits}"
    IO.puts "     - Misses: #{stats.misses}"
    IO.puts "     - Size: #{stats.size}"
    IO.puts "     - Hit rate: #{stats.hit_rate}"

  error ->
    IO.puts "   ✗ Failed to get statistics: #{inspect(error)}"
    System.halt(1)
end

# Test key generation
IO.puts "\n6. Testing key generation..."
mock_conn = %Plug.Conn{
  method: "POST",
  request_path: "/api/v1/orchestrate",
  query_string: "session=abc&strategy=auto",
  assigns: %{
    current_user: %{user_id: "test_user"},
    raw_body: ~s({"input": "test"})
  }
}

key = DedupCache.build_dedup_key(mock_conn)
IO.puts "   ✓ Key generated: #{String.slice(key, 0, 80)}..."

# Verify key components
assert String.contains?(key, "test_user:post:/api/v1/orchestrate")
assert String.contains?(key, "session=abc&strategy=auto")
IO.puts "     - Contains user_id"
IO.puts "     - Contains normalized query string"

# Test TTL determination
IO.puts "\n7. Testing TTL determination..."
ttl1 = DedupCache.ttl_for_path("/api/v1/orchestrate")
ttl2 = DedupCache.ttl_for_path("/api/v1/orchestrate/complex")
ttl3 = DedupCache.ttl_for_path("/api/v1/tasks")

IO.puts "   ✓ TTL determined for paths:"
IO.puts "     - /api/v1/orchestrate: #{ttl1}ms (tier 1)"
IO.puts "     - /api/v1/orchestrate/complex: #{ttl2}ms (tier 2)"
IO.puts "     - /api/v1/tasks: #{ttl3}ms (tier 3)"

# Verify cleanup
IO.puts "\n8. Testing cleanup..."
DedupCache.clear()
case DedupCache.stats() do
  {:ok, stats} ->
    if stats.size == 0 do
      IO.puts "   ✓ Cache cleared successfully"
    else
      IO.puts "   ✗ Cache not cleared: size = #{stats.size}"
      System.halt(1)
    end

  error ->
    IO.puts "   ✗ Failed to get stats after clear: #{inspect(error)}"
    System.halt(1)
end

IO.puts "\n=== All Verifications Passed ✓ ==="
