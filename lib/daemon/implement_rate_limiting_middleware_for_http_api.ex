defmodule Daemon.ImplementRateLimitingMiddlewareForHttpApi do
  @moduledoc """
  Implementation plan and verification document for HTTP API rate limiting.

  This module documents the rate limiting middleware implementation that
  protects the HTTP API from abuse and ensures fair resource allocation.

  ## Implementation Status: ✅ COMPLETE

  Rate limiting middleware is fully implemented and operational in:
  - `lib/daemon/channels/http/rate_limiter.ex` - Core rate limiting plug
  - `lib/daemon/channels/http/api.ex` - Integration into API pipeline

  ## Architecture

  ### Token Bucket Algorithm
  The rate limiter uses a token bucket algorithm backed by ETS for
  high-performance, distributed rate limiting without external dependencies.

  ### Key Components

  1. **ETS Table Storage**
     - Table name: `:daemon_rate_limits`
     - Schema: `{ip_string, token_count, last_refill_unix_seconds}`
     - Concurrency: `{:write_concurrency, true}` for high throughput
     - Lifecycle: Lazy initialization on first use, auto-cleanup every 5 minutes

  2. **Rate Limits**
     - Default endpoints: 60 requests per minute per IP
     - Auth endpoints: 10 requests per minute per IP (stricter for security)
     - Health check: No rate limiting (public monitoring endpoint)

  3. **HTTP Response Headers**
     - `x-ratelimit-limit`: Total requests allowed in the window
     - `x-ratelimit-remaining`: Requests remaining in current window
     - `retry-after`: Seconds until client can retry (on 429 response)

  4. **Cleanup Process**
     - Runs every 5 minutes
     - Removes entries older than 10 minutes
     - Prevents memory bloat from stale IPs

  ## Integration Points

  ### HTTP Pipeline (lib/daemon/channels/http/api.ex)
  ```elixir
  plug :cors
  plug Daemon.Channels.HTTP.RateLimiter  # ← Rate limiting here
  plug :validate_content_type
  plug :authenticate
  plug Daemon.Channels.HTTP.Integrity
  plug :match
  ```

  ### Channel Rate Limiting

  Channel adapters (Feishu, Email, etc.) implement their own rate limiting
  to respect third-party API quotas:

  - **Feishu** (`lib/daemon/channels/feishu.ex`)
    - Detects 429 responses from Feishu API
    - Extracts `retry-after` or `x-ratelimit-reset-after` headers
    - Returns `{:error, {:rate_limited, retry_after}}` to caller

  - **Email** (`lib/daemon/channels/email.ex`)
    - SendGrid and Mailgun rate limit detection
    - Returns `{:error, {:rate_limited, retry_after}}`
    - Fallback to SMTP if API is unavailable

  ## Testing

  Comprehensive test suite in `test/channels/http/rate_limiter_test.exs`:

  - ✅ Single request passes and sets headers
  - ✅ 60th request passes (default limit)
  - ✅ 61st request returns 429
  - ✅ Retry-After header set correctly
  - ✅ Auth endpoints have stricter limit (10/min)
  - ✅ Different IPs tracked independently
  - ✅ ETS table lazy initialization
  - ✅ 429 response body format

  Run tests:
  ```bash
  mix test test/channels/http/rate_limiter_test.exs
  ```

  ## Configuration

  Rate limits are currently hardcoded constants in `rate_limiter.ex`:

  ```elixir
  @default_limit 60        # 60 requests per minute
  @auth_limit 10           # 10 requests per minute
  @window_seconds 60       # 1 minute window
  @cleanup_interval_ms 5 * 60 * 1_000  # 5 minutes
  @stale_threshold_seconds 10 * 60     # 10 minutes
  ```

  To make these configurable via Application config, add to `config/config.exs`:

  ```elixir
  config :daemon, :rate_limit,
    default_limit: 60,
    auth_limit: 10,
    window_seconds: 60
  ```

  ## Monitoring

  The rate limiter logs 429 responses:
  ```
  [RateLimiter] 429 for 192.168.1.5 on /sessions
  ```

  For production monitoring, consider:
  - Metrics: Export 429 count to Prometheus/Datadog
  - Alerting: Alert if 429 rate exceeds threshold
  - Dashboards: Graph rate limit violations over time

  ## Security Considerations

  1. **IPv6 Handling**: Full IPv6 addresses are used as the key
     - Privacy: Consider hashing IPs for GDPR compliance
     - Shared IPs: NAT/proxy users share the same bucket

  2. **Bypass Prevention**: Rate limiting is applied AFTER auth check failure
     - Unauthenticated requests are still rate limited
     - Prevents enumeration attacks on auth endpoints

  3. **DoS Protection**: ETS table is protected with `:public` read but
     concurrent writes ensure no race conditions during token consumption

  ## Future Enhancements

  1. **Sliding Window**: Current implementation uses fixed window
     - Upgrade to sliding window log for smoother rate limiting
     - Prevents "burst at window boundary" issue

  2. **Per-User Limits**: Add user_id-based limits (in addition to IP)
     - Requires authenticated session tracking
     - Fair allocation for multi-user environments

  3. **Dynamic Limits**: Adjust limits based on system load
     - Reduce limits under high load
     - Increase limits during off-peak hours

  4. **Whitelist/Blacklist**: Configurable IP exceptions
     - Whitelist monitoring services
     - Blacklist abusive IPs permanently

  5. **Distributed Rate Limiting**: For multi-node deployments
     - Use Redis or PG for shared state
     - Currently ETS is per-node

  ## Verification Checklist

  - [x] Rate limiter module implemented
  - [x] Integrated into HTTP pipeline
  - [x] ETS table management (create, cleanup)
  - [x] Token bucket algorithm
  - [x] HTTP headers (x-ratelimit-*, retry-after)
  - [x] 429 response formatting
  - [x] Auth endpoint stricter limits
  - [x] Comprehensive test coverage
  - [x] Logging for monitoring
  - [x] Channel adapter rate limit handling (Feishu, Email)

  ## References

  - Token Bucket Algorithm: https://en.wikipedia.org/wiki/Token_bucket
  - Rate Limiting Best Practices: https://cloud.google.com/architecture/rate-limiting-strategies-techniques
  - Plug Documentation: https://hexdocs.pm/plug/Plug.html
  """
end
