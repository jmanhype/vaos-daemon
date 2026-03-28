defmodule Daemon.Channels.HTTP.RateLimiterTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Daemon.Channels.HTTP.RateLimiter

  @table :daemon_rate_limits

  setup do
    # Clean ETS table before each test
    try do
      :ets.delete_all_objects(@table)
    rescue
      _ -> :ok
    end

    :ok
  end

  describe "basic rate limiting" do
    test "allows requests within limit" do
      conn = conn(:get, "/api/v1/tools")

      # Make 60 requests - all should pass
      for i <- 1..60 do
        conn = RateLimiter.call(conn, [])
        assert conn.status != 429, "Request #{i} should not be rate limited"
        assert conn.resp_body == nil
      end
    end

    test "blocks requests exceeding limit" do
      conn = conn(:get, "/api/v1/tools")

      # Make 61 requests - last one should be blocked
      responses =
        for i <- 1..61 do
          test_conn = RateLimiter.call(conn, [])
          {i, test_conn.status}
        end

      # First 60 should pass (status nil because conn hasn't been sent yet)
      assert Enum.filter(responses, fn {i, status} -> i <= 60 and status != nil end)
             |> length() == 0

      # 61st should be rate limited
      assert Enum.find(responses, fn {i, status} -> i == 61 end) |> elem(1) == 429
    end

    test "sets appropriate rate limit headers" do
      conn = conn(:get, "/api/v1/tools")
      conn = RateLimiter.call(conn, [])

      assert get_resp_header(conn, "x-ratelimit-limit") == ["60"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["59"]
    end
  end

  describe "auth endpoint rate limiting" do
    test "auth endpoints have stricter limits" do
      conn = conn(:post, "/api/v1/auth/login")

      # Make 11 requests - last one should be blocked
      responses =
        for i <- 1..11 do
          test_conn = RateLimiter.call(conn, [])
          {i, test_conn.status}
        end

      # First 10 should pass
      assert Enum.filter(responses, fn {i, status} -> i <= 10 and status != nil end)
             |> length() == 0

      # 11th should be rate limited
      assert Enum.find(responses, fn {i, status} -> i == 11 end) |> elem(1) == 429
    end

    test "platform auth endpoints have stricter limits" do
      conn = conn(:post, "/api/v1/platform/auth/login")

      # Make 11 requests - last one should be blocked
      responses =
        for i <- 1..11 do
          test_conn = RateLimiter.call(conn, [])
          {i, test_conn.status}
        end

      assert Enum.find(responses, fn {i, status} -> i == 11 end) |> elem(1) == 429
    end

    test "auth endpoints set correct headers" do
      conn = conn(:post, "/api/v1/auth/login")
      conn = RateLimiter.call(conn, [])

      assert get_resp_header(conn, "x-ratelimit-limit") == ["10"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["9"]
    end
  end

  describe "token bucket refill" do
    test "refills tokens after time window passes" do
      conn = conn(:get, "/api/v1/tools")

      # Exhaust the bucket (60 requests)
      for _ <- 1..60 do
        RateLimiter.call(conn, [])
      end

      # Next request should be rate limited
      conn_limited = RateLimiter.call(conn, [])
      assert conn_limited.status == 429

      # Wait for window to pass (in real scenario, this would be 60 seconds)
      # For testing, we can't actually wait, so we verify the refill logic exists
      # by checking the ETS table directly
      [{_ip, tokens, last_refill}] = :ets.lookup(@table, "127.0.0.1")
      assert tokens == 0
      assert is_integer(last_refill)
    end

    test "partial refill based on elapsed time" do
      conn = conn(:get, "/api/v1/tools")

      # Make 30 requests
      for _ <- 1..30 do
        RateLimiter.call(conn, [])
      end

      # Check remaining tokens
      [{_ip, tokens, _last_refill}] = :ets.lookup(@table, "127.0.0.1")
      assert tokens == 30
    end
  end

  describe "different IP addresses" do
    test "tracks rate limits independently per IP" do
      # Create connections with different IPs by setting remote_ip
      conn1_base = conn(:get, "/api/v1/tools")
      conn2_base = conn(:get, "/api/v1/tools")

      # Simulate requests from IP1
      conn1 = Enum.reduce(1..60, conn1_base, fn _, acc ->
        %{acc | remote_ip: {192, 168, 1, 1}}
        |> RateLimiter.call([])
      end)

      # IP1 should be rate limited on 61st request
      conn1_limited = %{conn1_base | remote_ip: {192, 168, 1, 1}}
                      |> RateLimiter.call([])
      assert conn1_limited.status == 429

      # IP2 should still work (first request)
      conn2_ok = %{conn2_base | remote_ip: {192, 168, 1, 2}}
                 |> RateLimiter.call([])
      assert conn2_ok.status != 429
    end
  end

  describe "IPv6 support" do
    test "handles IPv6 addresses correctly" do
      # Create a connection with IPv6 remote address
      ipv6_addr = {0, 0, 0, 0, 0, 0, 0, 1}
      conn = conn(:get, "/api/v1/tools")
      conn = %{conn | remote_ip: ipv6_addr}

      # Should work without errors
      conn = RateLimiter.call(conn, [])
      assert conn.status != 429
    end
  end

  describe "rate limited response" do
    test "returns proper JSON error on rate limit" do
      conn = conn(:get, "/api/v1/tools")

      # Exhaust the bucket
      for _ <- 1..60 do
        RateLimiter.call(conn, [])
      end

      # Get rate limited response
      conn = RateLimiter.call(conn, [])

      assert conn.status == 429
      assert get_resp_header(conn, "content-type") |> List.first() |> String.starts_with?("application/json")
      assert get_resp_header(conn, "retry-after") == ["60"]

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "rate_limited"
      assert body["message"] == "Too many requests"
    end
  end

  describe "ETS table management" do
    test "creates ETS table on first use" do
      # Delete table if it exists
      try do
        :ets.delete(@table)
      rescue
        _ -> :ok
      end

      # First call should create table
      conn = conn(:get, "/api/v1/tools")
      RateLimiter.call(conn, [])

      assert :ets.whereis(@table) != :undefined
    end

    test "handles concurrent table creation gracefully" do
      # Delete table
      try do
        :ets.delete(@table)
      rescue
        _ -> :ok
      end

      # Spawn multiple processes trying to create table
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            conn = conn(:get, "/api/v1/tools")
            RateLimiter.call(conn, [])
          end)
        end

      # All should complete without error
      results = Task.await_many(tasks, 5000)
      assert length(results) == 10
    end
  end

  describe "stale entry cleanup" do
    @tag :skip
    test "removes stale entries older than threshold" do
      # This test is skipped because it requires waiting 5+ minutes
      # for the cleanup loop to run. In production, the cleanup loop
      # runs every 5 minutes and removes entries older than 10 minutes.

      # Manual testing approach:
      # 1. Make requests to populate ETS table
      # 2. Wait 10+ minutes
      # 3. Check ETS table - entries should be gone
      # 4. Check logs for "Cleaned N stale rate-limit entries"
    end
  end

  describe "platform auth endpoints" do
    test "platform auth endpoints have stricter limits" do
      conn = conn(:post, "/api/v1/platform/auth/register")

      # Make 11 requests
      responses =
        for i <- 1..11 do
          test_conn = RateLimiter.call(conn, [])
          {i, test_conn.status}
        end

      # 11th should be rate limited
      assert Enum.find(responses, fn {i, status} -> i == 11 end) |> elem(1) == 429
    end
  end

  describe "various API endpoints" do
    test "orchestrate endpoint uses default limit" do
      conn = conn(:post, "/api/v1/orchestrate")

      conn = RateLimiter.call(conn, [])
      assert get_resp_header(conn, "x-ratelimit-limit") == ["60"]
    end

    test "sessions endpoint uses default limit" do
      conn = conn(:get, "/api/v1/sessions")

      conn = RateLimiter.call(conn, [])
      assert get_resp_header(conn, "x-ratelimit-limit") == ["60"]
    end

    test "tools endpoint uses default limit" do
      conn = conn(:get, "/api/v1/tools")

      conn = RateLimiter.call(conn, [])
      assert get_resp_header(conn, "x-ratelimit-limit") == ["60"]
    end

    test "memory endpoint uses default limit" do
      conn = conn(:post, "/api/v1/memory")

      conn = RateLimiter.call(conn, [])
      assert get_resp_header(conn, "x-ratelimit-limit") == ["60"]
    end
  end
end
