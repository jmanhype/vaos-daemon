defmodule Daemon.ImplementCircuitBreakerPatternForExternalLlm do
  @moduledoc """
  Circuit breaker pattern implementation for external LLM provider calls.

  This module provides a unified interface to the circuit breaker system
  that protects against cascading failures when calling external LLM providers.

  ## Overview

  The circuit breaker pattern prevents the system from repeatedly trying to
  call a failing provider, which would waste resources and degrade performance.
  When a provider fails repeatedly, the circuit "opens" and requests are
  automatically routed to fallback providers.

  ## Circuit States

    - `:closed`    — Provider is healthy, requests flow normally
    - `:open`      — Provider has failed repeatedly; requests are blocked
    - `:half_open` — Cooldown expired; next request probes if provider recovered

  ## Thresholds

    - Opens after 3 consecutive failures
    - Half-opens after 30 seconds of being open
    - Closes after 1 successful request in `:half_open` state
    - Rate-limited providers are blocked for 60 seconds (or Retry-After duration)

  ## Usage

      # Check if a provider is available before making a call
      if ImplementCircuitBreakerPatternForExternalLlm.available?(:anthropic) do
        # Make the LLM call
      else
        # Use fallback or cached response
      end

      # Record outcomes (typically done automatically by Providers.Registry)
      ImplementCircuitBreakerPatternForExternalLlm.record_success(:anthropic)
      ImplementCircuitBreakerPatternForExternalLlm.record_failure(:groq, :timeout)
      ImplementCircuitBreakerPatternForExternalLlm.record_rate_limited(:openai, 30)

      # Get current state for monitoring
      ImplementCircuitBreakerPatternForExternalLlm.status()

  ## Integration with Noise Filter

  The noise filter (`Daemon.Channels.NoiseFilter`) prevents low-signal messages
  from reaching LLM providers entirely, which reduces load and helps prevent
  rate limiting. This is a complementary pattern to the circuit breaker.

  ## Integration with Channel Startup

  The circuit breaker GenServer starts during infrastructure initialization
  (before the provider registry) to ensure it's available when providers
  begin making requests.

  ## API Endpoints

  The HTTP API exposes circuit breaker status at:
    - GET /api/v1/models/status — Returns health status of all providers
  """

  use GenServer
  require Logger

  alias Daemon.Providers.HealthChecker

  @doc """
  Start the circuit breaker GenServer.

  Typically started as part of the infrastructure supervision tree.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Check if a provider is available for requests.

  Returns `false` when:
  - Circuit is `:open` (and cooldown has not expired)
  - Provider is rate-limited (and rate-limit window has not expired)

  ## Examples

      iex> available?(:anthropic)
      true

      iex> available?(:groq)
      false  # Circuit is open or rate-limited

  """
  @spec available?(atom()) :: boolean()
  def available?(provider) when is_atom(provider) do
    HealthChecker.is_available?(provider)
  end

  @doc """
  Record a successful provider call.

  This closes the circuit if it was in `:half_open` state and resets
  the failure counter.

  ## Examples

      available?(:anthropic)
      # ... make LLM call, it succeeds ...
      record_success(:anthropic)

  """
  @spec record_success(atom()) :: :ok
  def record_success(provider) when is_atom(provider) do
    HealthChecker.record_success(provider)
  end

  @doc """
  Record a failed provider call.

  After 3 consecutive failures, the circuit opens and subsequent calls
  will be blocked until the cooldown period expires.

  ## Examples

      record_failure(:groq, :timeout)
      record_failure(:openai, {:http_error, 503})
      record_failure(:anthropic, "rate limit exceeded")

  """
  @spec record_failure(atom(), term()) :: :ok
  def record_failure(provider, reason) when is_atom(provider) do
    HealthChecker.record_failure(provider, reason)
  end

  @doc """
  Record that the provider returned HTTP 429 (rate limited).

  Marks the provider as rate-limited for `retry_after_seconds` (default 60).

  ## Examples

      record_rate_limited(:openai, 30)
      record_rate_limited(:anthropic, nil)  # Uses default 60s

  """
  @spec record_rate_limited(atom(), non_neg_integer() | nil) :: :ok
  def record_rate_limited(provider, retry_after_seconds \\ nil)
      when is_atom(provider) do
    HealthChecker.record_rate_limited(provider, retry_after_seconds)
  end

  @doc """
  Get the current circuit status for all tracked providers.

  Returns a map where keys are provider atoms and values are maps with:
    - `:circuit` — Current state (:closed, :open, :half_open)
    - `:consecutive_failures` — Number of consecutive failures
    - `:opened_at` — Timestamp when circuit opened (nil if not open)
    - `:rate_limited_until` — Timestamp when rate limit expires (nil if not rate-limited)

  ## Examples

      iex> status()
      %{
        anthropic: %{
          circuit: :closed,
          consecutive_failures: 0,
          opened_at: nil,
          rate_limited_until: nil
        },
        groq: %{
          circuit: :open,
          consecutive_failures: 3,
          opened_at: 1710528400000,
          rate_limited_until: nil
        }
      }

  """
  @spec status() :: map()
  def status do
    HealthChecker.state()
  end

  @doc """
  Get a human-readable summary of circuit breaker state.

  Useful for logging and monitoring dashboards.

  ## Examples

      iex> summary()
      "Circuit breakers: anthropic=closed, groq=open (3 failures), openai=closed"

  """
  @spec summary() :: String.t()
  def summary do
    state = status()

    provider_summaries =
      Enum.map(state, fn {provider, data} ->
        circuit_status = data.circuit

        failure_info =
          case data.consecutive_failures do
            0 -> ""
            n -> " (#{n} failures)"
          end

        rate_limit_info =
          if data.rate_limited_until do
            until_ms = data.rate_limited_until - System.monotonic_time(:millisecond)
            if until_ms > 0 do
              " (rate-limited #{div(until_ms, 1000)}s)"
            else
              ""
            end
          else
            ""
          end

        "#{provider}=#{circuit_status}#{failure_info}#{rate_limit_info}"
      end)

    case provider_summaries do
      [] -> "No providers tracked"
      summaries -> "Circuit breakers: #{Enum.join(summaries, ", ")}"
    end
  end

  @doc """
  Reset a provider's circuit breaker to `:closed` state.

  This is typically only needed for manual recovery or testing purposes.
  The circuit will auto-recover through normal operation.

  ## Examples

      reset(:groq)  # Manually close the circuit for groq

  """
  @spec reset(atom()) :: :ok
  def reset(provider) when is_atom(provider) do
    # To reset, we record success which closes the circuit
    Logger.warning("[CircuitBreaker] Manual reset requested for #{provider}")
    record_success(provider)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(:ok) do
    Logger.info("[CircuitBreaker] Circuit breaker interface started")
    {:ok, %{}}
  end

  @impl true
  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
