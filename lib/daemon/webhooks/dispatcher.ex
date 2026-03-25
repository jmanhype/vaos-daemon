defmodule Daemon.Webhooks.Dispatcher do
  @moduledoc """
  Outbound webhook dispatcher.

  Maintains a registry of (url, secret, event_filter) entries in ETS and
  forwards matching OSA events to registered URLs via HTTP POST.

  Each delivery is fire-and-forget in an async Task with up to 3 retries
  and exponential backoff.  If a secret is configured the payload is signed
  with HMAC-SHA256 and sent as `X-OSA-Signature: sha256=<hex>`.

  ## Public API

      Dispatcher.register("https://example.com/hook")
      Dispatcher.register("https://example.com/hook", "mysecret", ["llm_response"])
      Dispatcher.unregister("abc123")
      Dispatcher.list()
  """
  use GenServer
  require Logger

  @table :daemon_webhooks
  @blocked_hosts ~w[localhost 0.0.0.0 127.0.0.1 ::1]

  # ── Public API ────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Register a webhook. Returns `{:ok, id}` or `{:error, reason}`."
  @spec register(String.t(), String.t() | nil, [String.t()]) ::
          {:ok, String.t()} | {:error, String.t() | :invalid_url}
  def register(url, secret \\ nil, filter \\ []) do
    cond do
      not valid_url?(url) -> {:error, :invalid_url}
      not valid_secret?(secret) -> {:error, "secret must be at least 32 bytes"}
      true -> GenServer.call(__MODULE__, {:register, url, secret, filter})
    end
  end

  @doc "Unregister a webhook by id."
  @spec unregister(String.t()) :: :ok | {:error, :not_found}
  def unregister(id) do
    GenServer.call(__MODULE__, {:unregister, id})
  end

  @doc "List all registered webhooks (secret is never exposed)."
  @spec list() :: [map()]
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, entry} ->
      entry
      |> Map.delete(:secret)
      |> Map.put(:has_secret, not is_nil(entry.secret))
    end)
    |> Enum.sort_by(& &1.created_at)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Daemon.PubSub, "osa:events")
    Logger.debug("[Webhooks.Dispatcher] started")
    {:ok, :no_state}
  end

  @impl true
  def handle_call({:register, url, secret, filter}, _from, state) do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    entry = %{
      id: id,
      url: url,
      secret: secret,
      filter: filter,
      created_at: System.os_time(:second)
    }

    :ets.insert(@table, {id, entry})
    {:reply, {:ok, id}, state}
  end

  def handle_call({:unregister, id}, _from, state) do
    case :ets.lookup(@table, id) do
      [] -> {:reply, {:error, :not_found}, state}
      _ -> :ets.delete(@table, id); {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:daemon_event, event}, state) do
    dispatch_all(event)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ──────────────────────────────────────────────────────────

  defp dispatch_all(event) do
    event_type = event |> Map.get(:type) |> to_string()

    @table
    |> :ets.tab2list()
    |> Enum.each(fn {_id, entry} ->
      if matches_filter?(entry.filter, event_type) do
        Task.start(fn -> deliver_with_retry(entry, event) end)
      end
    end)
  end

  defp matches_filter?([], _type), do: true
  defp matches_filter?(filter, type), do: type in filter

  defp deliver_with_retry(entry, event, attempts \\ 3) do
    case deliver(entry, event) do
      :ok -> :ok
      {:error, _} when attempts > 1 ->
        Process.sleep(1000 * (4 - attempts))
        deliver_with_retry(entry, event, attempts - 1)
      {:error, reason} ->
        Logger.warning("[Webhooks] permanently failed delivery to #{entry.url}: #{inspect(reason)}")
    end
  end

  defp deliver(entry, event) do
    url = entry.url
    json = Jason.encode!(event)
    headers = build_headers(json, entry.secret)
    req_headers = Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)

    case Req.post(url, body: json, headers: [{"content-type", "application/json"} | req_headers], receive_timeout: 5_000) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp build_headers(_json, nil), do: []

  defp build_headers(json, secret) do
    sig = :crypto.mac(:hmac, :sha256, secret, json) |> Base.encode16(case: :lower)
    [{"x-osa-signature", "sha256=" <> sig}]
  end

  @doc false
  def valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
        host_lower = String.downcase(host)
        not (host_lower in @blocked_hosts) and
          not String.starts_with?(host_lower, "169.254.") and
          not String.starts_with?(host_lower, "10.") and
          not String.starts_with?(host_lower, "192.168.")
      _ -> false
    end
  end

  def valid_url?(_), do: false

  @doc false
  def valid_secret?(nil), do: true
  def valid_secret?(s) when is_binary(s) and byte_size(s) >= 32, do: true
  def valid_secret?(_), do: false
end
