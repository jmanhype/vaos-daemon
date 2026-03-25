defmodule Daemon.Channels.HTTP.API.Shared do
  @moduledoc """
  Pure utility functions shared across API sub-routers.
  """
  import Plug.Conn

  @doc """
  Send a JSON error response with status code.

  SECURITY: `details` must be a caller-supplied static string.
  Never pass `inspect(reason)` or any internal error term as `details`
  — doing so may leak stack traces, configuration values, or prompt content
  to the client.
  """
  def json_error(conn, status, error, details) do
    body =
      case Jason.encode(%{error: error, details: details}) do
        {:ok, json} -> json
        {:error, _} -> Jason.encode!(%{error: error})
      end

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

  @doc "Send a JSON response with any data."
  def json(conn, status, data) do
    body =
      case Jason.encode(data) do
        {:ok, json} -> json
        {:error, _} -> Jason.encode!(%{error: "internal_error"})
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  @doc "Parse page/per_page from query params."
  def pagination_params(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    page = parse_positive_int(conn.query_params["page"], 1)
    per_page = conn.query_params["per_page"] |> parse_positive_int(20) |> min(100)
    {page, per_page}
  end

  @doc "Parse a positive integer from string, returning default on failure."
  def parse_positive_int(nil, default), do: default

  def parse_positive_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  def parse_positive_int(_, default), do: default

  @doc "Traverse an Ecto changeset and return human-readable error map."
  def changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts
        |> Keyword.get(String.to_existing_atom(key), key)
        |> to_string()
      end)
    end)
  end
end
