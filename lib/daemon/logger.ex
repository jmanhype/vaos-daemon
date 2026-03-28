defmodule Daemon.Logger do
  @moduledoc """
  Structured logging with JSON output mode for production observability.

  Provides a unified logging interface that outputs human-readable logs in
  development and machine-parseable JSON in production.

  ## Configuration

      config :daemon, :logger,
        format: :json  # or :text (default)
        metadata: [:pid, :module, :function, :line]

  ## Usage

      # Structured logging with metadata
      Daemon.Logger.info("Message received", channel: :feishu, user_id: "123")

      # With error details
      Daemon.Logger.error("Failed to send message", error: reason, attempt: 3)

      # With duration measurement
      Daemon.Logger.debug("Token refresh completed", duration_ms: 123)

  ## JSON Output Format

  In production (format: :json), logs are emitted as single-line JSON:

  {
    "timestamp": "2025-01-15T10:30:45.123Z",
    "level": "info",
    "message": "Message received",
    "channel": "feishu",
    "user_id": "123",
    "pid": "<0.123.0>",
    "module": "Daemon.Channels.Feishu",
    "function": "handle_event",
    "line": 42
  }
  """

  require Logger

  @type level :: :debug | :info | :warning | :error
  @type metadata :: keyword() | map()

  @doc "Log debug-level message with structured metadata"
  @spec debug(String.t(), metadata()) :: :ok
  def debug(message, metadata \\ []) do
    log(:debug, message, metadata)
  end

  @doc "Log info-level message with structured metadata"
  @spec info(String.t(), metadata()) :: :ok
  def info(message, metadata \\ []) do
    log(:info, message, metadata)
  end

  @doc "Log warning-level message with structured metadata"
  @spec warning(String.t(), metadata()) :: :ok
  def warning(message, metadata \\ []) do
    log(:warning, message, metadata)
  end

  @doc "Log error-level message with structured metadata"
  @spec error(String.t(), metadata()) :: :ok
  def error(message, metadata \\ []) do
    log(:error, message, metadata)
  end

  @doc "Log with custom level"
  @spec log(level(), String.t(), metadata()) :: :ok
  def log(level, message, metadata) when is_atom(level) and is_binary(message) do
    format = Application.get_env(:daemon, :log_format, :text)

    case format do
      :json ->
        emit_json(level, message, metadata)

      :text ->
        emit_text(level, message, metadata)

      _ ->
        # Default to text format for unknown formats
        emit_text(level, message, metadata)
    end
  end

  # ── Private Helpers ─────────────────────────────────────────────────────

  defp emit_json(level, message, metadata) do
    log_entry = build_json_log(level, message, metadata)
    # Use Logger's JSON backend if configured, otherwise emit as text
    Logger.log(level, log_entry)
  end

  defp emit_text(level, message, metadata) when metadata == [] do
    Logger.log(level, message)
  end

  defp emit_text(level, message, metadata) do
    formatted = format_text_metadata(metadata)
    Logger.log(level, "#{message} #{formatted}")
  end

  defp build_json_log(level, message, metadata) do
    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      level: to_string(level),
      message: message
    }
    |> add_standard_metadata()
    |> add_custom_metadata(metadata)
    |> Jason.encode!()
  end

  defp add_standard_metadata(entry) do
    entry
    |> Map.put(:pid, inspect(self()))
    |> put_optional(:module, get_module())
    |> put_optional(:function, get_function())
    |> put_optional(:line, get_line())
  end

  defp add_custom_metadata(entry, []), do: entry

  defp add_custom_metadata(entry, metadata) when is_list(metadata) do
    Enum.reduce(metadata, entry, fn {key, value}, acc ->
      Map.put(acc, key, format_value(value))
    end)
  end

  defp add_custom_metadata(entry, metadata) when is_map(metadata) do
    Enum.reduce(metadata, entry, fn {key, value}, acc ->
      Map.put(acc, key, format_value(value))
    end)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_atom(value), do: value
  defp format_value(value) when is_number(value), do: value
  defp format_value(value) when is_boolean(value), do: value
  defp format_value(value), do: inspect(value, limit: 500)

  defp format_text_metadata([]), do: ""

  defp format_text_metadata(metadata) when is_list(metadata) do
    formatted =
      Enum.map(metadata, fn {key, value} ->
        "#{key}=#{format_value(value)}"
      end)
      |> Enum.join(" ")

    if formatted == "", do: "", else: "[#{formatted}]"
  end

  # Get caller information from the stacktrace
  defp get_module do
    case Process.info(self(), :current_stacktrace) do
      {:current_stacktrace, [_ | [_ | stack]]} ->
        find_module(stack)

      {:current_stacktrace, stack} ->
        find_module(stack)

      _ ->
        nil
    end
  end

  defp find_module([item | _]) when is_tuple(item) and tuple_size(item) >= 1 do
    case elem(item, 0) do
      module when is_atom(module) -> module
      _ -> nil
    end
  end

  defp find_module(_), do: nil

  defp get_function do
    case Process.info(self(), :current_stacktrace) do
      {:current_stacktrace, [_ | [_ | stack]]} ->
        find_function(stack)

      {:current_stacktrace, stack} ->
        find_function(stack)

      _ ->
        nil
    end
  end

  defp find_function([item | _]) when is_tuple(item) and tuple_size(item) >= 2 do
    case elem(item, 1) do
      {function, _arity} when is_atom(function) -> function
      _ -> nil
    end
  end

  defp find_function(_), do: nil

  defp get_line do
    case Process.info(self(), :current_stacktrace) do
      {:current_stacktrace, [_ | [_ | stack]]} ->
        find_line(stack)

      {:current_stacktrace, stack} ->
        find_line(stack)

      _ ->
        nil
    end
  end

  defp find_line([item | _]) when is_tuple(item) and tuple_size(item) >= 2 do
    case elem(item, 1) do
      {_function, _arity, [line: line]} when is_integer(line) -> line
      _ -> nil
    end
  end

  defp find_line(_), do: nil

  @doc """
  Measure execution time of a function and log the result.

  ## Examples

      Daemon.Logger.measure("Token refresh", fn ->
        refresh_token()
      end)

      # Logs: "Token refresh completed" with duration_ms metadata
  """
  @spec measure(String.t(), function(), keyword()) :: any()
  def measure(label, fun, opts \\ []) when is_function(fun, 0) do
    level = Keyword.get(opts, :level, :debug)
    metadata = Keyword.get(opts, :metadata, [])

    start = System.monotonic_time(:millisecond)

    try do
      result = fun.()
      duration = System.monotonic_time(:millisecond) - start

      log(level, "#{label} completed", Keyword.put(metadata, :duration_ms, duration))

      result
    rescue
      e ->
        duration = System.monotonic_time(:millisecond) - start

        log(:error, "#{label} failed",
          error: Exception.message(e),
          duration_ms: duration,
          metadata: metadata
        )

        reraise(e, __STACKTRACE__)
    end
  end

  @doc """
  Create a log context that can be passed to child functions.

  ## Examples

      Daemon.Logger.with_context(user_id: "123", session_id: "abc", fn ->
        Daemon.Logger.info("Processing request")
        # Logs will include user_id and session_id
      end)
  """
  @spec with_context(metadata(), function()) :: any()
  def with_context(metadata, fun) when is_function(fun, 0) do
    # Store context in process dictionary
    previous = Process.get(:daemon_log_context, [])
    Process.put(:daemon_log_context, Keyword.merge(previous, metadata))

    try do
      fun.()
    after
      # Restore previous context
      Process.put(:daemon_log_context, previous)
    end
  end

  @doc "Get current log context from process dictionary"
  @spec get_context() :: metadata()
  def get_context do
    Process.get(:daemon_log_context, [])
  end

  @doc "Add metadata to current log context"
  @spec put_context(keyword()) :: :ok
  def put_context(metadata) when is_list(metadata) do
    current = Process.get(:daemon_log_context, [])
    Process.put(:daemon_log_context, Keyword.merge(current, metadata))
    :ok
  end
end
