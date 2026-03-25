defmodule Daemon.Agent.Loop.LLMClient do
  @moduledoc """
  LLM call abstraction for the agent loop.

  Wraps Providers.chat and Providers.chat_stream with per-session
  provider/model routing, streaming callback setup, thinking config,
  and idle-timeout detection (kills connections that go silent).
  """
  require Logger

  alias MiosaProviders.Registry, as: Providers
  alias Daemon.Events.Bus

  # If no streaming token arrives for this long, the connection is dead.
  # This is NOT a total-duration cap — active streams can run indefinitely.
  @idle_timeout_ms 120_000

  @doc """
  Synchronous LLM chat — routes through the configured provider/model for this session.
  """
  def llm_chat(%{provider: provider, model: model}, messages, opts) do
    Logger.debug("[llm] chat — #{length(messages)} messages (sanitized): #{inspect(sanitize_for_log(messages))}")
    opts = if provider, do: Keyword.put(opts, :provider, provider), else: opts
    opts = if model, do: Keyword.put(opts, :model, model), else: opts
    Providers.chat(messages, opts)
  end

  @doc """
  Streaming LLM chat with idle-timeout detection.

  The stream can run for hours as long as tokens keep arriving. If the
  connection goes silent (no text_delta, thinking_delta, or done event
  for #{@idle_timeout_ms}ms), the call is killed and an error returned.

  Returns {:ok, result} | {:error, reason}.
  """
  def llm_chat_stream(%{session_id: session_id, provider: provider, model: model}, messages, opts) do
    Logger.debug("[llm] stream — #{length(messages)} messages (sanitized): #{inspect(sanitize_for_log(messages))} session=#{session_id}")
    # Heartbeat: atomics counter incremented on every streaming event.
    # The watchdog checks if the counter has changed since last poll.
    heartbeat = :atomics.new(1, signed: false)
    :atomics.put(heartbeat, 1, 1)

    caller = self()

    callback = fn
      {:text_delta, text} ->
        :atomics.add(heartbeat, 1, 1)
        Logger.debug("[stream] text_delta #{byte_size(text)}B → session:#{session_id}")
        Bus.emit(:system_event, %{
          event: :streaming_token,
          session_id: session_id,
          delta: text
        })

      {:done, result} ->
        :atomics.add(heartbeat, 1, 1)
        Logger.info("[stream] done → session:#{session_id}")
        send(caller, {:llm_stream_done, result})

      {:thinking_delta, text} ->
        :atomics.add(heartbeat, 1, 1)
        Bus.emit(:system_event, %{
          event: :thinking_delta,
          session_id: session_id,
          delta: text
        })

      _other ->
        :atomics.add(heartbeat, 1, 1)
        :ok
    end

    opts = if provider, do: Keyword.put(opts, :provider, provider), else: opts
    opts = if model, do: Keyword.put(opts, :model, model), else: opts

    # Run the stream in a linked task so we can kill it on idle timeout
    stream_task = Task.async(fn ->
      Providers.chat_stream(messages, callback, opts)
    end)

    # Watchdog: polls heartbeat every 10s, kills if no progress for @idle_timeout_ms
    idle_timeout = Keyword.get(opts, :idle_timeout, @idle_timeout_ms)
    watchdog = spawn_link(fn -> watchdog_loop(heartbeat, stream_task, idle_timeout, session_id) end)

    # Wait for stream completion or idle timeout
    result =
      receive do
        {:llm_stream_done, stream_result} ->
          # Stream completed normally — clean up watchdog
          Process.unlink(watchdog)
          Process.exit(watchdog, :normal)
          # Wait for the task to finish (it should be done already)
          Task.await(stream_task, 5_000)
          {:ok, stream_result}

        {:llm_idle_timeout, elapsed_ms} ->
          # Watchdog detected idle connection — kill the stream
          Logger.warning("[stream] Idle timeout after #{div(elapsed_ms, 1000)}s of silence — killing stream for session:#{session_id}")
          Task.shutdown(stream_task, :brutal_kill)
          {:error, "LLM stream went silent for #{div(elapsed_ms, 1000)}s — connection likely dropped"}

      after
        # Absolute safety net: 1 hour. Should never fire for legitimate work.
        3_600_000 ->
          Logger.error("[stream] Absolute timeout (1h) hit for session:#{session_id}")
          Process.unlink(watchdog)
          Process.exit(watchdog, :normal)
          Task.shutdown(stream_task, :brutal_kill)
          {:error, "LLM stream exceeded 1 hour absolute limit"}
      end

    result
  rescue
    e ->
      Logger.error("[stream] Exception in llm_chat_stream: #{inspect(e)}")
      {:error, "Stream error: #{inspect(e)}"}
  end

  # Watchdog process: polls heartbeat counter every 10s.
  # If the counter hasn't changed for `timeout_ms`, sends idle timeout signal.
  defp watchdog_loop(heartbeat, stream_task, timeout_ms, session_id) do
    poll_interval = 10_000
    last_count = :atomics.get(heartbeat, 1)
    watchdog_poll(heartbeat, stream_task, timeout_ms, session_id, poll_interval, last_count, 0)
  end

  defp watchdog_poll(heartbeat, stream_task, timeout_ms, session_id, poll_interval, last_count, idle_ms) do
    Process.sleep(poll_interval)

    # Check if stream task is still alive
    unless Process.alive?(stream_task.pid) do
      # Stream finished — watchdog can exit
      :ok
    else
      current_count = :atomics.get(heartbeat, 1)

      if current_count == last_count do
        # No progress — accumulate idle time
        new_idle = idle_ms + poll_interval

        if new_idle >= timeout_ms do
          # Idle timeout exceeded — notify caller
          Logger.warning("[watchdog] No stream activity for #{div(new_idle, 1000)}s — session:#{session_id}")
          send(stream_task.owner, {:llm_idle_timeout, new_idle})
        else
          watchdog_poll(heartbeat, stream_task, timeout_ms, session_id, poll_interval, last_count, new_idle)
        end
      else
        # Progress detected — reset idle counter
        watchdog_poll(heartbeat, stream_task, timeout_ms, session_id, poll_interval, current_count, 0)
      end
    end
  end

  @doc "Resolve thinking config based on provider, model, and application config."
  def thinking_config(%{provider: provider} = state) do
    enabled = Application.get_env(:daemon, :thinking_enabled, false)

    if enabled and provider in [:anthropic, nil] and is_anthropic_provider?() do
      model = state.model || Application.get_env(:daemon, :anthropic_model, "claude-sonnet-4-6")

      if String.contains?(to_string(model), "opus") do
        %{type: "adaptive"}
      else
        budget = Application.get_env(:daemon, :thinking_budget_tokens, 5_000)
        %{type: "enabled", budget_tokens: budget}
      end
    else
      nil
    end
  end

  @doc "Returns true when the configured default provider is Anthropic."
  def is_anthropic_provider? do
    default = Application.get_env(:daemon, :default_provider, :ollama)
    default == :anthropic
  end

  @doc "Returns the configured LLM temperature."
  def temperature, do: Application.get_env(:daemon, :temperature, 0.7)

  # ── Log sanitization (Bug 17) ─────────────────────────────────────────────
  # Strip system-prompt content from any message list before it touches a
  # Logger call.  The messages are sent to the LLM unchanged — only the copy
  # that appears in log output is redacted.
  #
  # Rules:
  #   - Messages with role "system" (atom or string key) have their content
  #     replaced with the literal string "[REDACTED: system prompt]".
  #   - All other messages are returned as-is.
  #   - Any non-map element is passed through unchanged (defensive).
  @spec sanitize_for_log(list()) :: list()
  defp sanitize_for_log(messages) when is_list(messages) do
    Enum.map(messages, fn
      # Atom-key map with role: "system"
      %{role: "system"} = msg ->
        %{msg | content: "[REDACTED: system prompt]"}

      # String-key map with "role" => "system" (decoded JSON / checkpoint restore)
      %{"role" => "system"} = msg ->
        %{msg | "content" => "[REDACTED: system prompt]"}

      # All other messages — pass through unchanged
      msg ->
        msg
    end)
  end

  defp sanitize_for_log(other), do: other
end
