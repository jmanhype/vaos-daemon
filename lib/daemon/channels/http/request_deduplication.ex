defmodule Daemon.Channels.HTTP.RequestDeduplication do
  @moduledoc "Request deduplication plug for preventing duplicate task submissions."
  @behaviour Plug

  require Logger
  import Plug.Conn

  @table :daemon_request_dedup
  @default_window_ms 10_000
  @cleanup_interval_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    if orchestrate_path?(conn.request_path) do
      ensure_table()

      case check_and_record(conn) do
        {:ok, _fingerprint} ->
          put_resp_header(conn, "x-dedup-id", Base.encode16(<<System.unique_integer([:positive, :monotonic])::64>>, case: :lower))

        {:error, :duplicate} ->
          Logger.info("[RequestDedup] Rejected duplicate request from #{conn.assigns[:user_id]} on #{conn.request_path}")

          body = Jason.encode!(%{
            error: "duplicate_request",
            message: "An identical request was recently submitted. Please wait before retrying."
          })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(409, body)
          |> halt()
      end
    else
      conn
    end
  end

  def check_and_record(conn) do
    user_id = conn.assigns[:user_id] || "anonymous"
    fingerprint = compute_fingerprint(conn, user_id)
    now = System.system_time(:millisecond)

    case :ets.lookup(@table, {fingerprint, user_id}) do
      [] ->
        :ets.insert(@table, {{fingerprint, user_id}, now})
        {:ok, fingerprint}

      [{_key, timestamp}] ->
        window_ms = get_window_ms()

        if now - timestamp < window_ms do
          {:error, :duplicate}
        else
          :ets.insert(@table, {{fingerprint, user_id}, now})
          {:ok, fingerprint}
        end
    end
  end

  def compute_fingerprint(conn, user_id) do
    body = conn.body_params || %{}

    task_input = cond do
      is_binary(body["input"]) -> body["input"]
      is_binary(body["task"]) -> body["task"]
      true -> ""
    end

    options = %{
      session_id: body["session_id"],
      skip_plan: body["skip_plan"],
      strategy: body["strategy"],
      max_agents: body["max_agents"],
      auto_dispatch: body["auto_dispatch"]
    }

    fingerprint_data = [
      user_id,
      conn.method,
      conn.request_path,
      task_input,
      :erlang.term_to_binary(options)
    ]

    :crypto.hash(:sha256, :erlang.iolist_to_binary(fingerprint_data))
    |> Base.encode16(case: :lower)
  end

  def cleanup_stale do
    try do
      cutoff = System.system_time(:millisecond) - get_window_ms() * 2
      ms = [{{{:_, :_}, :"$1"}, [{:<, :"$1", cutoff}], [true]}]
      deleted = :ets.select_delete(@table, ms)

      if deleted > 0 do
        Logger.debug("[RequestDedup] Cleaned #{deleted} stale entries")
      end
    rescue
      ArgumentError -> :ok
    end
  end

  defp orchestrate_path?(path) when is_binary(path) do
    String.starts_with?(path, "/api/v1/orchestrate") or
      String.starts_with?(path, "/api/v1/orchestrator") or
      String.starts_with?(path, "/api/v1/swarm/launch")
  end

  defp get_window_ms do
    Application.get_env(:daemon, :request_dedup_window_ms, @default_window_ms)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}, {:read_concurrency, true}])
        spawn_cleanup_loop()
      _tid -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp spawn_cleanup_loop do
    spawn(fn -> cleanup_loop() end)
  end

  defp cleanup_loop do
    Process.sleep(@cleanup_interval_ms)
    cleanup_stale()
    cleanup_loop()
  end
end
