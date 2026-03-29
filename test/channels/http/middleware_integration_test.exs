defmodule Daemon.Channels.HTTP.MiddlewareIntegrationTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Daemon.Channels.HTTP.{RateLimiter, Integrity, Auth}

  @table_rate_limits :daemon_rate_limits
  @table_nonces :daemon_integrity_nonces
  @secret "integration-test-secret"

  # ── Setup ───────────────────────────────────────────────────────────────

  setup do
    # Clean ETS tables
    case :ets.whereis(@table_rate_limits) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table_rate_limits)
    end

    case :ets.whereis(@table_nonces) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table_nonces)
    end

    # Configure auth and integrity
    original_auth = Application.get_env(:daemon, :require_auth)
    original_secret = Application.get_env(:daemon, :shared_secret)

    Application.put_env(:daemon, :require_auth, true)
    Application.put_env(:daemon, :shared_secret, @secret)

    on_exit(fn ->
      if original_auth,
        do: Application.put_env(:daemon, :require_auth, original_auth),
        else: Application.delete_env(:daemon, :require_auth)

      if original_secret,
        do: Application.put_env(:daemon, :shared_secret, original_secret),
        else: Application.delete_env(:daemon, :shared_secret)
    end)

    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp generate_token do
    Auth.generate_token(%{"user_id" => "test-user", "workspace_id" => "test-workspace"})
  end

  defp sign_request(timestamp, nonce, body) do
    payload = "#{timestamp}\n#{nonce}\n#{body}"
    :crypto.mac(:hmac, :sha256, @secret, payload) |> Base.encode16(case: :lower)
  end

  defp build_conn(path, body, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, System.system_time(:second))

    nonce =
      Keyword.get(
        opts,
        :nonce,
        "nonce_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
      )

    include_token = Keyword.get(opts, :token, true)
    include_signature = Keyword.get(opts, :signature, true)

    signature = sign_request(to_string(timestamp), nonce, body)

    conn(:post, path, body)
    |> put_req_header("content-type", "application/json")
    |> maybe_add_auth(include_token, generate_token())
    |> maybe_add_signature(include_signature, timestamp, nonce, signature)
    |> assign(:raw_body, body)
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
  end

  defp maybe_add_auth(conn, true, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
  defp maybe_add_auth(conn, false, _token), do: conn

  defp maybe_add_signature(conn, true, timestamp, nonce, signature) do
    conn
    |> put_req_header("x-osa-signature", signature)
    |> put_req_header("x-osa-timestamp", to_string(timestamp))
    |> put_req_header("x-osa-nonce", nonce)
  end

  defp maybe_add_signature(conn, false, _, _, _), do: conn

  defp run_middleware_pipeline(conn, path) do
    conn
    |> RateLimiter.call([])
    |> Integrity.call([])
  end

  # ── Integration Tests: Valid Requests ────────────────────────────────────

  describe "valid requests pass through middleware" do
    test "request with valid auth and signature succeeds" do
      body = ~s({"message": "hello world"})
      conn = build_conn("/api/v1/sessions", body)

      result = run_middleware_pipeline(conn, "/api/v1/sessions")

      refute result.halted
      refute result.status == 401
      refute result.status == 429
    end

    test "multiple valid requests from same IP increment rate limit counter" do
      ip = {192, 168, 1, 100}
      body = ~s({"test": "data"})

      # Make 10 requests
      conns =
        Enum.map(1..10, fn _ ->
          build_conn("/api/v1/sessions", body)
          |> Map.put(:remote_ip, ip)
          |> run_middleware_pipeline("/api/v1/sessions")
        end)

      # All should pass
      assert Enum.all?(conns, fn c -> not c.halted end)

      # Last request should show decreased remaining count
      last = List.last(conns)
      remaining = get_resp_header(last, "x-ratelimit-remaining") |> hd() |> String.to_integer()

      assert remaining == 50
    end

    test "different IPs have independent rate limits" do
      body = ~s({"test": "data"})

      # Exhaust IP A's limit
      ip_a = {10, 0, 0, 1}
      Enum.each(1..60, fn _ ->
        build_conn("/api/v1/sessions", body)
        |> Map.put(:remote_ip, ip_a)
        |> run_middleware_pipeline("/api/v1/sessions")
      end)

      # IP A should be rate limited
      conn_a =
        build_conn("/api/v1/sessions", body)
        |> Map.put(:remote_ip, ip_a)
        |> run_middleware_pipeline("/api/v1/sessions")

      assert conn_a.status == 429

      # IP B should still work
      ip_b = {10, 0, 0, 2}
      conn_b =
        build_conn("/api/v1/sessions", body)
        |> Map.put(:remote_ip, ip_b)
        |> run_middleware_pipeline("/api/v1/sessions")

      refute conn_b.halted
      refute conn_b.status == 429
    end
  end

  # ── Integration Tests: Rate Limiting ─────────────────────────────────────

  describe "rate limiting thresholds" do
    test "default endpoint: 60 requests per minute" do
      ip = {172, 16, 10, 1}
      body = ~s({"test": "default"})

      # Make 60 requests - all should pass
      for _ <- 1..60 do
        conn =
          build_conn("/api/v1/sessions", body)
          |> Map.put(:remote_ip, ip)
          |> run_middleware_pipeline("/api/v1/sessions")

        refute conn.halted
      end

      # 61st request should be rate limited
      conn =
        build_conn("/api/v1/sessions", body)
        |> Map.put(:remote_ip, ip)
        |> run_middleware_pipeline("/api/v1/sessions")

      assert conn.status == 429
      assert conn.halted
    end

    test "auth endpoint: 10 requests per minute" do
      ip = {172, 16, 20, 1}
      body = ~s({"test": "auth"})

      # Make 10 requests - all should pass
      for _ <- 1..10 do
        conn =
          build_conn("/api/v1/auth/login", body)
          |> Map.put(:remote_ip, ip)
          |> run_middleware_pipeline("/api/v1/auth/login")

        refute conn.halted
      end

      # 11th request should be rate limited
      conn =
        build_conn("/api/v1/auth/login", body)
        |> Map.put(:remote_ip, ip)
        |> run_middleware_pipeline("/api/v1/auth/login")

      assert conn.status == 429
    end

    test "rate limit resets after window expires" do
      ip = {172, 16, 30, 1}
      body = ~s({"test": "reset"})

      # Exhaust the limit (60 requests)
      Enum.each(1..60, fn _ ->
        build_conn("/api/v1/sessions", body)
        |> Map.put(:remote_ip, ip)
        |> run_middleware_pipeline("/api/v1/sessions")
      end)

      # Should be rate limited
      conn_limited =
        build_conn("/api/v1/sessions", body)
        |> Map.put(:remote_ip, ip)
        |> run_middleware_pipeline("/api/v1/sessions")

      assert conn_limited.status == 429

      # Manually expire the window by manipulating ETS
      # In real scenarios, this would take 60 seconds
      :ets.insert(@table_rate_limits, {format_ip(ip), 10, System.system_time(:second) - 70})

      # Next request should succeed
      conn_success =
        build_conn("/api/v1/sessions", body)
        |> Map.put(:remote_ip, ip)
        |> run_middleware_pipeline("/api/v1/sessions")

      refute conn_success.halted
      refute conn_success.status == 429
    end
  end

  # ── Integration Tests: Integrity Verification ───────────────────────────

  describe "integrity verification" do
    test "missing signature returns 401" do
      body = ~s({"message": "test"})
      conn = build_conn("/api/v1/sessions", body, signature: false)

      result = run_middleware_pipeline(conn, "/api/v1/sessions")

      assert result.status == 401
      assert result.halted
      assert result.resp_body =~ "integrity_check_failed"
    end

    test "invalid signature returns 401" do
      body = ~s({"message": "test"})
      conn =
        build_conn("/api/v1/sessions", body,
          signature: "deadbeef"
        )

      result = run_middleware_pipeline(conn, "/api/v1/sessions")

      assert result.status == 401
      assert result.halted
    end

    test "expired timestamp returns 401" do
      body = ~s({"message": "test"})
      old_timestamp = System.system_time(:second) - 400  # > 5 minutes ago

      conn = build_conn("/api/v1/sessions", body, timestamp: old_timestamp)

      result = run_middleware_pipeline(conn, "/api/v1/sessions")

      assert result.status == 401
      assert result.halted
    end

    test "replay attack is prevented" do
      body = ~s({"message": "test"})
      nonce = "replay-test-nonce"

      # First request succeeds
      conn1 = build_conn("/api/v1/sessions", body, nonce: nonce)
      result1 = run_middleware_pipeline(conn1, "/api/v1/sessions")

      refute result1.halted

      # Second request with same nonce fails
      conn2 = build_conn("/api/v1/sessions", body, nonce: nonce)
      result2 = run_middleware_pipeline(conn2, "/api/v1/sessions")

      assert result2.status == 401
      assert result2.halted
    end

    test "tampered body is rejected" do
      body = ~s({"message": "original"})

      # Sign original body
      conn =
        build_conn("/api/v1/sessions", body,
          nonce: "tamper-test"
        )

      # Tamper with the body after signing
      tampered_conn = assign(conn, :raw_body, ~s({"message": "tampered"}))
      tampered_conn = %{tampered_conn | body_params: %{"message" => "tampered"}}

      result = run_middleware_pipeline(tampered_conn, "/api/v1/sessions")

      assert result.status == 401
      assert result.halted
    end
  end

  # ── Integration Tests: Combined Middleware ──────────────────────────────

  describe "combined middleware behavior" do
    test "rate limiting is checked before integrity" do
      ip = {192, 168, 100, 1}
      body = ~s({"test": "combined"})

      # Exhaust rate limit
      Enum.each(1..60, fn _ ->
        build_conn("/api/v1/sessions", body)
        |> Map.put(:remote_ip, ip)
        |> run_middleware_pipeline("/api/v1/sessions")
      end)

      # Even with valid signature, should be rate limited first
      conn =
        build_conn("/api/v1/sessions", body)
        |> Map.put(:remote_ip, ip)
        |> run_middleware_pipeline("/api/v1/sessions")

      # Rate limiter halts before integrity check
      assert conn.status == 429
      assert conn.halted
    end

    test "integrity failure prevents rate limit consumption" do
      ip = {192, 168, 101, 1}
      body = ~s({"test": "integrity-first"})

      # Make 10 requests with invalid signatures
      for _ <- 1..10 do
        build_conn("/api/v1/sessions", body, signature: false)
        |> Map.put(:remote_ip, ip)
        |> run_middleware_pipeline("/api/v1/sessions")
      end

      # Should still have full rate limit available
      # because integrity failed before rate limit was checked
      conn =
        build_conn("/api/v1/sessions", body)
        |> Map.put(:remote_ip, ip)
        |> run_middleware_pipeline("/api/v1/sessions")

      refute conn.status == 429
      remaining = get_resp_header(conn, "x-ratelimit-remaining") |> hd() |> String.to_integer()

      # Should have 59 remaining (only the successful request consumed)
      assert remaining == 59
    end
  end

  # ── Performance Tests ────────────────────────────────────────────────────

  describe "performance" do
    test "middleware adds minimal latency for valid requests" do
      body = ~s({"test": "performance"})

      start_time = System.monotonic_time(:microsecond)

      build_conn("/api/v1/sessions", body)
      |> run_middleware_pipeline("/api/v1/sessions")

      elapsed = System.monotonic_time(:microsecond) - start_time

      # Should complete in less than 50ms
      assert elapsed < 50_000
    end

    test "multiple concurrent requests are handled correctly" do
      body = ~s({"test": "concurrent"})
      ips = for i <- 1..10, do: {192, 168, i, 1}

      tasks =
        Enum.map(ips, fn ip ->
          Task.async(fn ->
            build_conn("/api/v1/sessions", body)
            |> Map.put(:remote_ip, ip)
            |> run_middleware_pipeline("/api/v1/sessions")
          end)
        end)

      results = Task.await_many(tasks, 5000)

      # All should succeed
      assert Enum.all?(results, fn c -> not c.halted end)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
end
