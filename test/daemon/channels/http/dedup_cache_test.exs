defmodule Daemon.Channels.HTTP.DedupCacheTest do
  use Daemon.DataCase
  alias Daemon.Channels.HTTP.DedupCache

  # Helper to create a mock Plug.Conn
  defp build_conn(method, path, query_string \\ "", body \\ "", user_id \\ "user_123") do
    %Plug.Conn{
      method: method,
      request_path: path,
      query_string: query_string,
      assigns: %{
        current_user: %{user_id: user_id},
        raw_body: body
      }
    }
  end

  describe "build_dedup_key/1" do
    test "builds key with user_id, method, and path" do
      conn = build_conn("POST", "/api/v1/orchestrate", "", "")

      key = DedupCache.build_dedup_key(conn)

      assert String.starts_with?(key, "user_123:post:/api/v1/orchestrate")
    end

    test "normalizes path to lowercase" do
      conn = build_conn("GET", "/API/V1/Tasks", "", "")

      key = DedupCache.build_dedup_key(conn)

      assert String.contains?(key, ":get:/api/v1/tasks")
    end

    test "sorts query parameters" do
      conn = build_conn("GET", "/api/v1/tasks", "b=2&a=1&c=3", "")

      key = DedupCache.build_dedup_key(conn)

      # Query string should be normalized: a=1&b=2&c=3
      assert String.contains?(key, "?a=1&b=2&c=3")
    end

    test "includes body hash for POST requests" do
      body = ~s({"input": "test"})
      conn = build_conn("POST", "/api/v1/orchestrate", "", body)

      key = DedupCache.build_dedup_key(conn)

      # Should contain SHA-256 hash of body
      assert String.contains?(key, ":")
      parts = String.split(key, ":")
      assert length(parts) >= 5

      # Last part is time_bucket, second to last is body_hash
      body_hash = Enum.at(parts, -2)
      assert String.length(body_hash) == 64  # SHA-256 hex length
    end

    test "excludes body hash for GET requests" do
      conn = build_conn("GET", "/api/v1/tasks", "", "")

      key = DedupCache.build_dedup_key(conn)

      # Should have empty body hash
      assert key =~ ":user_123:get:/api/v1/tasks::"
    end

    test "includes time bucket" do
      conn = build_conn("POST", "/api/v1/orchestrate", "", "")

      key = DedupCache.build_dedup_key(conn)

      # Last part should be time_bucket (integer as string)
      parts = String.split(key, ":")
      time_bucket = List.last(parts)
      assert String.match?(time_bucket, ~r/^\d+$/)
    end

    test "uses anonymous for unauthenticated requests" do
      conn = %Plug.Conn{
        method: "GET",
        request_path: "/api/v1/tasks",
        query_string: "",
        assigns: %{}
      }

      key = DedupCache.build_dedup_key(conn)

      assert String.starts_with?(key, "anonymous:get:/api/v1/tasks")
    end
  end

  describe "ttl_for_path/1" do
    test "returns tier 2 TTL for expensive orchestration" do
      assert DedupCache.ttl_for_path("/api/v1/orchestrate/complex") == 30_000
      assert DedupCache.ttl_for_path("/api/v1/swarm/launch") == 30_000
      assert DedupCache.ttl_for_path("/api/v1/sessions/create") == 30_000
    end

    test "returns tier 1 TTL for high-frequency operations (default)" do
      assert DedupCache.ttl_for_path("/api/v1/orchestrate") == 5_000
      assert DedupCache.ttl_for_path("/api/v1/sessions") == 5_000
    end

    test "returns tier 3 TTL for read-heavy operations" do
      assert DedupCache.ttl_for_path("/api/v1/tasks") == 120_000
      assert DedupCache.ttl_for_path("/api/v1/sessions") == 120_000
      assert DedupCache.ttl_for_path("/api/v1/agents") == 120_000
    end

    test "handles case-insensitive path matching" do
      assert DedupCache.ttl_for_path("/API/V1/ORCHESTRATE/COMPLEX") == 30_000
      assert DedupCache.ttl_for_path("/api/v1/TASKS") == 120_000
    end
  end

  describe "cache operations" do
    setup do
      # Clear cache before each test
      DedupCache.clear()
      :ok
    end

    test "put and get basic operation" do
      conn = build_conn("POST", "/api/v1/orchestrate", "", "")

      assert DedupCache.get(conn) == :miss

      response = %{
        status: 200,
        body: ~s({"result": "success"}),
        headers: [{"content-type", "application/json"}]
      }

      DedupCache.put_raw("test_key", response, 5_000)

      assert {:ok, ^response} = DedupCache.get_raw("test_key")
    end

    test "returns miss after TTL expires" do
      conn = build_conn("POST", "/api/v1/orchestrate", "", "")

      response = %{
        status: 200,
        body: ~s({"result": "success"}),
        headers: []
      }

      # Store with very short TTL
      DedupCache.put_raw("test_key", response, 10)

      # Should be cached immediately
      assert {:ok, ^response} = DedupCache.get_raw("test_key")

      # Wait for expiration
      Process.sleep(15)

      assert DedupCache.get_raw("test_key") == {:miss, :expired}
    end

    test "invalidate removes specific entry" do
      response = %{status: 200, body: "test", headers: []}

      DedupCache.put_raw("test_key", response, 5_000)
      assert {:ok, ^response} = DedupCache.get_raw("test_key")

      DedupCache.invalidate("test_key")
      assert DedupCache.get_raw("test_key") == :miss
    end

    test "clear removes all entries" do
      response = %{status: 200, body: "test", headers: []}

      DedupCache.put_raw("key1", response, 5_000)
      DedupCache.put_raw("key2", response, 5_000)

      assert {:ok, _} = DedupCache.get_raw("key1")
      assert {:ok, _} = DedupCache.get_raw("key2")

      DedupCache.clear()

      assert DedupCache.get_raw("key1") == :miss
      assert DedupCache.get_raw("key2") == :miss
    end

    test "stats tracks hits and misses" do
      response = %{status: 200, body: "test", headers: []}

      # Initial stats
      assert {:ok, stats} = DedupCache.stats()
      assert stats.hits == 0
      assert stats.misses == 0
      assert stats.size == 0

      # Add entry
      DedupCache.put_raw("test_key", response, 5_000)

      # Miss
      DedupCache.get_raw("nonexistent")
      assert {:ok, stats} = DedupCache.stats()
      assert stats.misses == 1

      # Hit
      DedupCache.get_raw("test_key")
      assert {:ok, stats} = DedupCache.stats()
      assert stats.hits == 1
      assert stats.size == 1

      # Hit rate calculation
      assert stats.hit_rate == 0.5
    end
  end

  describe "idempotency key support" do
    setup do
      DedupCache.clear()
      :ok
    end

    test "stores and retrieves idempotency keys" do
      user_id = "user_123"
      idempotency_key = "unique-op-123"
      scoped_key = "idempotency:#{user_id}:#{idempotency_key}"

      response = %{
        status: 201,
        body: ~s({"created": true}),
        headers: [{"content-type", "application/json"}]
      }

      # Store with idempotency TTL (24h default)
      DedupCache.put_idempotency(scoped_key, response.status, response.body, response.headers)

      # Retrieve
      assert {:ok, cached} = DedupCache.get_raw(scoped_key)
      assert cached.status == 201
      assert cached.body == ~s({"created": true})
    end

    test "scopes idempotency keys to user" do
      key = "shared-key"

      user1_response = %{status: 200, body: "user1", headers: []}
      user2_response = %{status: 200, body: "user2", headers: []}

      # Store for different users
      DedupCache.put_idempotency("idempotency:user1:#{key}", user1_response.status, user1_response.body, user1_response.headers)
      DedupCache.put_idempotency("idempotency:user2:#{key}", user2_response.status, user2_response.body, user2_response.headers)

      # Each user should get their own response
      assert {:ok, resp1} = DedupCache.get_raw("idempotency:user1:#{key}")
      assert resp1.body == "user1"

      assert {:ok, resp2} = DedupCache.get_raw("idempotency:user2:#{key}")
      assert resp2.body == "user2"
    end
  end

  describe "header filtering" do
    test "filters out non-cacheable headers" do
      conn = build_conn("GET", "/api/v1/tasks", "", "")

      headers = [
        {"content-type", "application/json"},
        {"date", "Wed, 21 Jan 2025 12:00:00 GMT"},
        {"server", "Daemon"},
        {"x-request-id", "abc-123"},
        {"cache-control", "no-cache"},
        {"x-custom", "custom-value"}
      ]

      DedupCache.put(conn, 200, "body", headers)

      assert {:ok, cached} = DedupCache.get(conn)

      # Should have content-type and x-custom
      assert Enum.any?(cached.headers, fn {k, _v} -> String.downcase(k) == "content-type" end)
      assert Enum.any?(cached.headers, fn {k, _v} -> String.downcase(k) == "x-custom" end)

      # Should NOT have date, server, x-request-id, cache-control
      refute Enum.any?(cached.headers, fn {k, _v} -> String.downcase(k) == "date" end)
      refute Enum.any?(cached.headers, fn {k, _v} -> String.downcase(k) == "server" end)
      refute Enum.any?(cached.headers, fn {k, _v} -> String.downcase(k) == "x-request-id" end)
      refute Enum.any?(cached.headers, fn {k, _v} -> String.downcase(k) == "cache-control" end)
    end
  end

  describe "integration with Plug.Conn" do
    setup do
      DedupCache.clear()
      :ok
    end

    test "full roundtrip: put and get with conn" do
      conn = build_conn("POST", "/api/v1/orchestrate", "", ~s({"task": "test"}))

      headers = [
        {"content-type", "application/json"},
        {"x-custom", "value"}
      ]

      # Cache miss
      assert DedupCache.get(conn) == :miss

      # Store response
      DedupCache.put(conn, 200, ~s({"result": "ok"}), headers)

      # Cache hit (same request within time bucket)
      assert {:ok, cached} = DedupCache.get(conn)
      assert cached.status == 200
      assert cached.body == ~s({"result": "ok"})
      assert length(cached.headers) == 2
    end

    test "different requests produce different keys" do
      conn1 = build_conn("POST", "/api/v1/orchestrate", "", ~s({"task": "a"}))
      conn2 = build_conn("POST", "/api/v1/orchestrate", "", ~s({"task": "b"}))

      key1 = DedupCache.build_dedup_key(conn1)
      key2 = DedupCache.build_dedup_key(conn2)

      # Body hashes should differ
      refute key1 == key2
    end

    test "same request has consistent key" do
      conn1 = build_conn("POST", "/api/v1/orchestrate?session=abc&strategy=auto", "", ~s({"task": "test"}))
      conn2 = build_conn("POST", "/api/v1/orchestrate?strategy=auto&session=abc", "", ~s({"task": "test"}))

      key1 = DedupCache.build_dedup_key(conn1)
      key2 = DedupCache.build_dedup_key(conn2)

      # Query params sorted, should be same key
      assert key1 == key2
    end
  end
end
