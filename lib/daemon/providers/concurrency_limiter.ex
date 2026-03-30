defmodule Daemon.Providers.ConcurrencyLimiter do
  @moduledoc """
  Global LLM concurrency limiter using ETS counters.

  Caps the total number of in-flight LLM API calls across all subsystems
  (WorkDirector, Orchestrator, SwarmMode, AutoFixer, Debate, Investigation, etc.)
  to prevent resource exhaustion on constrained hardware.

  Uses `:counters` (OTP atomic counters) — lock-free, no GenServer bottleneck,
  no deadlock risk. Callers that can't acquire a slot wait with exponential
  backoff up to a configurable timeout.
  """

  require Logger

  @max_concurrent Application.compile_env(:daemon, :llm_max_concurrent, 3)
  @acquire_timeout_ms Application.compile_env(:daemon, :llm_acquire_timeout_ms, 120_000)
  @backoff_base_ms 100
  @backoff_max_ms 5_000
  @counter_ref :daemon_llm_concurrency

  @doc "Initialize the concurrency limiter. Call once at application start."
  def init do
    counter = :counters.new(1, [:atomics])
    :persistent_term.put(@counter_ref, counter)
    :ok
  end

  @doc """
  Execute a function with concurrency limiting.

  Acquires a slot, runs `fun`, releases the slot. If no slot is available
  within `@acquire_timeout_ms`, returns `{:error, :llm_concurrency_timeout}`.
  """
  @spec with_limit((() -> term())) :: term()
  def with_limit(fun) when is_function(fun, 0) do
    case acquire(@acquire_timeout_ms) do
      :ok ->
        try do
          fun.()
        after
          release()
        end

      {:error, :timeout} ->
        Logger.warning("[ConcurrencyLimiter] Timeout waiting for LLM slot (max=#{@max_concurrent})")
        {:error, :llm_concurrency_timeout}
    end
  end

  @doc "Current number of in-flight LLM calls."
  @spec in_flight() :: non_neg_integer()
  def in_flight do
    counter = get_counter()
    :counters.get(counter, 1)
  end

  @doc "Maximum concurrent LLM calls allowed."
  def max_concurrent, do: @max_concurrent

  # -- Private --

  defp acquire(timeout_remaining) when timeout_remaining <= 0 do
    {:error, :timeout}
  end

  defp acquire(timeout_remaining) do
    counter = get_counter()
    current = :counters.get(counter, 1)

    if current < @max_concurrent do
      :counters.add(counter, 1, 1)
      # Double-check we didn't race past the limit
      new_val = :counters.get(counter, 1)
      if new_val > @max_concurrent do
        # Raced — back off and retry
        :counters.sub(counter, 1, 1)
        backoff = min(@backoff_base_ms, timeout_remaining)
        Process.sleep(backoff)
        acquire(timeout_remaining - backoff)
      else
        :ok
      end
    else
      # All slots taken — backoff with jitter
      jitter = :rand.uniform(@backoff_base_ms)
      backoff = min(@backoff_base_ms + jitter, min(@backoff_max_ms, timeout_remaining))
      Process.sleep(backoff)
      acquire(timeout_remaining - backoff)
    end
  end

  defp release do
    counter = get_counter()
    :counters.sub(counter, 1, 1)
  end

  defp get_counter do
    case :persistent_term.get(@counter_ref, nil) do
      nil ->
        # Auto-init if not yet started (defensive)
        init()
        :persistent_term.get(@counter_ref)

      counter ->
        counter
    end
  end
end
