defmodule OptimalSystemAgent.Channels.HTTP.API.Shared do
  @moduledoc """
  Pure utility functions shared across API sub-routers.
  """
  import Plug.Conn

  @doc "Send a JSON error response with status code."
  def json_error(conn, status, error, details) do
    body = Jason.encode!(%{error: error, details: details})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  @doc "Generate a unique HTTP session ID."
  def generate_session_id do
    "http_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end

  @doc "Unwrap GenServer results that may return {:ok, data} tuples or raw maps."
  def unwrap_ok({:ok, data}), do: data
  def unwrap_ok(data) when is_map(data), do: data
  def unwrap_ok(_), do: %{}

  @doc "Only include in keyword list when value is non-nil."
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc "Parse a task status string to atom."
  def parse_task_status(nil), do: nil
  def parse_task_status("completed"), do: :completed
  def parse_task_status("failed"), do: :failed
  def parse_task_status(_), do: nil

  @doc "Parse an integer from string, nil-safe."
  def parse_int(nil), do: nil

  def parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def parse_int(n) when is_integer(n), do: n
end
