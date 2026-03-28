defmodule Daemon.AddStructuredLoggingWithJsonOutputModeForP do
  @moduledoc """
  Migration/Setup module for structured logging with JSON output mode.

  This module provides helpers for enabling structured logging across the daemon.
  """

  @doc """
  Enable JSON logging for production environments.

  Call this from your application startup or configuration:

      Daemon.AddStructuredLoggingWithJsonOutputModeForP.enable_json_logging()
  """
  def enable_json_logging do
    Application.put_env(:daemon, :log_format, :json, persistent: true)
    :ok
  end

  @doc """
  Enable text logging (default for development).

      Daemon.AddStructuredLoggingWithJsonOutputModeForP.enable_text_logging()
  """
  def enable_text_logging do
    Application.put_env(:daemon, :log_format, :text, persistent: true)
    :ok
  end

  @doc """
  Check current logging format.

  Returns :json or :text
  """
  def current_format do
    Application.get_env(:daemon, :log_format, :text)
  end

  @doc """
  Get recommended logging configuration for the given environment.

  ## Examples

      iex> Daemon.AddStructuredLoggingWithJsonOutputModeForP.recommended_config(:prod)
      [format: :json, level: :info]

      iex> Daemon.AddStructuredLoggingWithJsonOutputModeForP.recommended_config(:dev)
      [format: :text, level: :debug]
  """
  def recommended_config(env) when env in [:prod, :production] do
    [
      format: :json,
      level: :info,
      metadata: [:pid, :module, :function, :line, :request_id, :session_id]
    ]
  end

  def recommended_config(env) when env in [:dev, :development] do
    [
      format: :text,
      level: :debug,
      metadata: [:pid, :module]
    ]
  end

  def recommended_config(_env) do
    [format: :text, level: :info]
  end

  @doc """
  Apply recommended configuration for the current environment.

  This is typically called from config/runtime.exs:

      config :daemon, :logger,
        Daemon.AddStructuredLoggingWithJsonOutputModeForP.recommended_config(config_env())
        |> Enum.into(%{})
  """
  def apply_recommended_config do
    env = Mix.env()

    recommended_config(env)
    |> Enum.each(fn {key, value} ->
      Application.put_env(:daemon, key, value, persistent: true)
    end)

    :ok
  end
end
