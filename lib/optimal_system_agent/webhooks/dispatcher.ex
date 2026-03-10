defmodule OptimalSystemAgent.Webhooks.Dispatcher do
  @moduledoc """
  Outbound webhook dispatcher.

  Maintains a registry of (url, secret, event_filter) entries in ETS and
  forwards matching OSA events to registered URLs via HTTP POST.

  Each delivery is fire-and-forget in an async Task with a 5-second
  timeout.  If a secret is configured the payload is signed with
  HMAC-SHA256 and sent as `X-OSA-Signature: sha256=<hex>`.

  ## Public API

      Dispatcher.register("https://example.com/hook")
      Dispatcher.register("https://example.com/hook", "mysecret", ["llm_response"])
      Dispatcher.unregister("abc123")
      Dispatcher.list()
  """
  use GenServer
  require Logger

  @table :osa_webhooks

  # ── Public API ────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Register a webhook. Returns `{:ok, id}` or `{:error, :invalid_url}`."
  @spec register(String.t(), String.t() | nil, [String.t()]) ::
          {:ok, String.t()} | {:error, :invalid_url}
  def register(url, secret \\ nil, filter \\ []) do
    if valid_url?(url) do
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      entry = %{
        id: id,
        url: url,
        secret: secret,
        filter: filter,
        created_at: System.os_time(:second)
      }

      :ets.insert(@table, {id, entry})
      {:ok, id}
    else
      {:error, :invalid_url}
    end
  end

  @doc "Unregister a webhook by id."
  @spec unregister(String.t()) :: :ok | {:error, :not_found}
  def unregister(id) do
    case :ets.lookup(@table, id) do
      [] -> {:error, :not_found}
      _ -> :ets.delete(@table, id); :ok
    end
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
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:events")
    Logger.debug("[Webhooks.Dispatcher] started")
    {:ok, :no_state}
  end

  @impl true
  def handle_info({:osa_event, event}, state) do
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
        Task.start(fn -> deliver(entry, event) end)
      end
    end)
  end

  defp matches_filter?([], _type), do: true
  defp matches_filter?(filter, type), do: type in filter

  defp deliver(%{url: url, secret: secret}, event) do
    case Jason.encode(event) do
      {:ok, json} ->
        headers = build_headers(json, secret)
        request = {String.to_charlist(url), headers, ~c"application/json", json}

        case :httpc.request(:post, request, [{:timeout, 5000}], []) do
          {:ok, _} ->
            Logger.debug("[Webhooks.Dispatcher] delivered to #{url}")

          {:error, reason} ->
            Logger.warning("[Webhooks.Dispatcher] delivery failed to #{url}: #{inspect(reason)}")
        end

      {:error, _} ->
        :ok
    end
  end

  defp build_headers(_json, nil), do: []

  defp build_headers(json, secret) do
    sig = :crypto.mac(:hmac, :sha256, secret, json) |> Base.encode16(case: :lower)
    [{~c"x-osa-signature", String.to_charlist("sha256=" <> sig)}]
  end

  defp valid_url?(url) when is_binary(url) do
    String.starts_with?(url, "http://") or String.starts_with?(url, "https://")
  end

  defp valid_url?(_), do: false
end
