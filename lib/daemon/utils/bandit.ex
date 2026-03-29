defmodule Daemon.Utils.Bandit do
  @moduledoc """
  Bandit HTTP server utilities and helpers.

  This module provides utility functions for working with the Bandit
  HTTP server that powers the Daemon HTTP channel.

  Bandit is the HTTP server used by Daemon to serve the Plug.Router
  application on the configured port (default: 8089).

  ## Configuration

  The server port can be configured via:
  - `DAEMON_HTTP_PORT` environment variable
  - `:http_port` application configuration
  - Default: 8089

  ## Examples

      iex> Daemon.Utils.Bandit.port()
      8089

      iex> Daemon.Utils.Bandit.port(%{"DAEMON_HTTP_PORT" => "4000"})
      4000

  """

  @default_port 8089
  @env_var "DAEMON_HTTP_PORT"
  @app_name :daemon
  @config_key :http_port

  @doc """
  Returns the configured HTTP port for the Bandit server.

  Checks in order:
  1. Environment variable `DAEMON_HTTP_PORT`
  2. Application config `:daemon, :http_port`
  3. Default value (8089)

  ## Examples

      iex> Daemon.Utils.Bandit.port()
      8089

  """
  @spec port() :: pos_integer()
  def port do
    case System.get_env(@env_var) do
      nil -> application_port()
      port_str -> parse_port(port_str)
    end
  end

  @doc """
  Returns the configured HTTP port with a custom environment map.

  Useful for testing with custom environment variables.

  ## Examples

      iex> Daemon.Utils.Bandit.port(%{"DAEMON_HTTP_PORT" => "4000"})
      4000

  """
  @spec port(map()) :: pos_integer()
  def port(env_map) when is_map(env_map) do
    case Map.get(env_map, @env_var) do
      nil -> application_port()
      port_str -> parse_port(port_str)
    end
  end

  @doc """
  Returns the health check URL for the Bandit server.

  ## Examples

      iex> Daemon.Utils.Bandit.health_url()
      "http://localhost:8089/health"

  """
  @spec health_url() :: String.t()
  def health_url do
    "http://localhost:#{port()}/health"
  end

  @doc """
  Returns the base URL for the Bandit server.

  ## Examples

      iex> Daemon.Utils.Bandit.base_url()
      "http://localhost:8089"

  """
  @spec base_url() :: String.t()
  def base_url do
    "http://localhost:#{port()}"
  end

  @doc """
  Checks if the Bandit server is configured to use the default port.

  ## Examples

      iex> Daemon.Utils.Bandit.default_port?()
      true

  """
  @spec default_port?() :: boolean()
  def default_port? do
    port() == @default_port
  end

  @doc """
  Returns the server configuration as a keyword list suitable for
  passing to Bandit.start_link/1.

  ## Examples

      iex> Daemon.Utils.Bandit.server_config()
      [plug: Daemon.Channels.HTTP, port: 8089]

  """
  @spec server_config() :: keyword()
  def server_config do
    [
      plug: Daemon.Channels.HTTP,
      port: port()
    ]
  end

  @doc """
  Validates that a port number is in the valid range (1-65535).

  ## Examples

      iex> Daemon.Utils.Bandit.valid_port?(8089)
      true

      iex> Daemon.Utils.Bandit.valid_port?(0)
      false

      iex> Daemon.Utils.Bandit.valid_port?(70000)
      false

  """
  @spec valid_port?(integer()) :: boolean()
  def valid_port?(port) when is_integer(port) and port > 0 and port <= 65535, do: true
  def valid_port?(_), do: false

  # Private functions

  defp application_port do
    Application.get_env(@app_name, @config_key, @default_port)
  end

  defp parse_port(port_str) when is_binary(port_str) do
    case Integer.parse(port_str) do
      {port, ""} when port > 0 and port <= 65535 -> port
      _ -> @default_port
    end
  end

  defp parse_port(_), do: @default_port
end
