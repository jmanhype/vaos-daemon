defmodule Daemon.Channels.HTTP.RateLimiter do
  @moduledoc """
  Token-bucket rate limiting plug backed by ETS.

  No external dependencies. Uses `:daemon_rate_limits` ETS table keyed by
  client IP. Two limits are enforced:

    - Auth paths (`/api/v1/auth/`, `/api/v1/platform/auth/`): 10 requests per minute
    - All other paths:                                      60 requests per minute

  The table is initialized lazily on first call and a periodic cleanup
  process removes stale entries every 5 minutes (entries older than
  10 minutes).

  ETS row schema: {ip_string, token_count, last_refill_unix_seconds}

  ## Configuration

  Rate limits can be configured via application config:

      config :daemon, :rate_limiter,
        default_limit: 60,           # Default requests per minute
        auth_limit: 10,              # Auth endpoint requests per minute
        window_seconds: 60,          # Time window in seconds
        cleanup_interval_ms: 300_000 # Cleanup interval (5 minutes)
        stale_threshold_seconds: 600 # Stale entry threshold (10 minutes)

  ## Custom Limits per Route

  You can configure custom limits for specific routes:

      config :daemon, :rate_limiter,
        route_limits: %{
          "/api/v1/orchestrate" => 30,
          "/api/v1/tools" => 100
        }

  ## Sliding Window

  The rate limiter uses a token bucket algorithm with proportional refill.
  Tokens are refilled based on elapsed time within the window, providing
  a smooth rate limit rather than a fixed window reset.

  ## Headers

  Rate limit information is exposed via HTTP headers:

      X-RateLimit-Limit: 60
      X-RateLimit-Remaining: 59
      X-RateLimit-Reset: 1640000000

  When rate limited, the response includes:

      Retry-After: 60

  ## Example

      # In your Plug.Router
      plug Daemon.Channels.HTTP.RateLimiter

      # Or with custom options
      plug Daemon.Channels.HTTP.RateLimiter, limit: 100

  """

  @behaviour Plug

  require Logger

  import Plug.Conn

  @table :daemon_rate_limits

  # Default limits
  @default_limit 60
  @auth_limit 10
  @window_seconds 60

  # Cleanup defaults
  @cleanup_interval_ms 5 * 60 * 1_000
  @stale_threshold_seconds 10 * 60

  # ── Plug callbacks ──────────────────────────────────────────────────────

  @impl Plug
  def init(opts) do
    # Support custom limit from plug options
    Keyword.get(opts, :limit, :default)
  end

  @impl Plug
  def call(conn, custom_limit) do
    ensure_table()
    ip = format_ip(conn.remote_ip)
    limit = get_limit(conn.request_path, custom_limit)

    case check_and_consume(ip, limit) do
      {:ok, remaining} ->
        conn
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", Integer.to_string(remaining))
        |> put_resp_header("x-ratelimit-reset", reset_timestamp())

      {:error, :rate_limited} ->
        Logger.warning("[RateLimiter] 429 for #{ip} on #{conn.request_path}")

        body = Jason.encode!(%{error: "rate_limited", message: "Too many requests"})

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("retry-after", Integer.to_string(@window_seconds))
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> put_resp_header("x-ratelimit-reset", reset_timestamp())
        |> send_resp(429, body)
        |> halt()
    end
  end

  # ── Token bucket ────────────────────────────────────────────────────────

  defp check_and_consume(ip, limit) do
    now = unix_now()

    case :ets.lookup(@table, ip) do
      [] ->
        # First request: full bucket minus this one
        :ets.insert(@table, {ip, limit - 1, now})
        {:ok, limit - 1}

      [{^ip, tokens, last_refill}] ->
        tokens_after_refill = refill(tokens, limit, last_refill, now)

        if tokens_after_refill > 0 do
          new_count = tokens_after_refill - 1
          :ets.insert(@table, {ip, new_count, now})
          {:ok, new_count}
        else
          {:error, :rate_limited}
        end
    end
  end

  # Refill proportionally to elapsed time within the window.
  # This provides a smooth rate limit rather than fixed window reset.
  defp refill(current_tokens, limit, last_refill, now) do
    elapsed = now - last_refill

    if elapsed >= @window_seconds do
      # Full window elapsed: reset to full
      limit
    else
      # Partial refill: add tokens proportional to elapsed fraction
      # This gives us a sliding window effect
      refill_amount = trunc(elapsed / @window_seconds * limit)
      min(current_tokens + refill_amount, limit)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp get_limit(path, custom_limit) when is_integer(custom_limit), do: custom_limit
  defp get_limit(path, []), do: get_limit(path, :default)

  defp get_limit(path, :default) do
    cond do
      String.starts_with?(path, "/api/v1/auth/") ->
        get_config(:auth_limit, @auth_limit)

      String.starts_with?(path, "/api/v1/platform/auth/") ->
        get_config(:auth_limit, @auth_limit)

      true ->
        # Check for custom route limits
        case get_route_limits() do
          %{^path => custom_limit} -> custom_limit
          _ -> get_config(:default_limit, @default_limit)
        end
    end
  end

  defp get_config(key, default) do
    case Application.get_env(:daemon, :rate_limiter) do
      nil -> default
      config when is_list(config) -> Keyword.get(config, key, default)
      _ -> default
    end
  end

  defp get_route_limits do
    case Application.get_env(:daemon, :rate_limiter) do
      nil -> %{}
      config when is_list(config) -> Keyword.get(config, :route_limits, %{})
      _ -> %{}
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(other), do: inspect(other)

  defp unix_now, do: System.system_time(:second)

  defp reset_timestamp do
    (unix_now() + @window_seconds)
    |> Integer.to_string()
  end

  # ── ETS lifecycle ───────────────────────────────────────────────────────

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
        spawn_cleanup_loop()

      _tid ->
        :ok
    end
  rescue
    # Race: two callers hit ensure_table simultaneously; second create fails.
    # That's fine — the table exists at this point.
    ArgumentError -> :ok
  end

  defp spawn_cleanup_loop do
    spawn(fn -> cleanup_loop() end)
  end

  defp cleanup_loop do
    interval = get_config(:cleanup_interval_ms, @cleanup_interval_ms)
    Process.sleep(interval)
    cleanup_stale()
    cleanup_loop()
  end

  defp cleanup_stale do
    try do
      threshold = get_config(:stale_threshold_seconds, @stale_threshold_seconds)
      cutoff = unix_now() - threshold

      # Delete any entry whose last_refill timestamp is older than the threshold.
      # Match spec: {ip, _tokens, last_refill} where last_refill < cutoff
      ms = [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}]
      deleted = :ets.select_delete(@table, ms)

      if deleted > 0 do
        Logger.debug("[RateLimiter] Cleaned #{deleted} stale rate-limit entries")
      end
    rescue
      ArgumentError -> :ok
    end
  end

  # ── Public API for inspection/testing ───────────────────────────────────

  @doc """
  Get current rate limit status for an IP address.

  Returns {:ok, %{remaining: integer, reset: unix_seconds}} or {:error, :not_found}.
  """
  def status(ip) when is_binary(ip) do
    case :ets.lookup(@table, ip) do
      [{^ip, tokens, last_refill}] ->
        reset = last_refill + @window_seconds
        {:ok, %{remaining: tokens, reset: reset}}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Reset rate limit for an IP address (for testing/admin).

  Use with caution - this bypasses rate limiting for the IP.
  """
  def reset(ip) when is_binary(ip) do
    :ets.delete(@table, ip)
    :ok
  end

  @doc """
  Get statistics about the rate limiter.

  Returns %{total_entries: integer, oldest_entry: unix_seconds | nil}.
  """
  def stats do
    try do
      entries = :ets.tab2list(@table)

      oldest =
        entries
        |> Enum.map(fn {_ip, _tokens, last_refill} -> last_refill end)
        |> Enum.min(fn -> nil end)

      %{total_entries: length(entries), oldest_entry: oldest}
    rescue
      ArgumentError -> %{total_entries: 0, oldest_entry: nil}
    end
  end
end
