defmodule OptimalSystemAgent.Tenant.Config do
  @moduledoc """
  ETS-backed per-tenant configuration management.

  Stores compute, LLM provider, and resource limit settings per tenant.
  """
  use GenServer
  require Logger

  @table :osa_tenant_config

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get full config for a tenant."
  @spec get(String.t()) :: map()
  def get(tenant_id) do
    case :ets.lookup(@table, tenant_id) do
      [{^tenant_id, config}] -> config
      [] -> default_config()
    end
  end

  @doc "Save full config for a tenant."
  @spec put(String.t(), map()) :: :ok
  def put(tenant_id, config) when is_map(config) do
    GenServer.call(__MODULE__, {:put, tenant_id, config})
  end

  @doc "Get LLM provider configs for a tenant."
  @spec get_llm_providers(String.t()) :: list()
  def get_llm_providers(tenant_id) do
    get(tenant_id) |> Map.get(:llm_providers, [])
  end

  @doc "Update LLM provider configs for a tenant."
  @spec set_llm_providers(String.t(), list()) :: :ok
  def set_llm_providers(tenant_id, providers) when is_list(providers) do
    GenServer.call(__MODULE__, {:update_key, tenant_id, :llm_providers, providers})
  end

  @doc "Get compute config for a tenant."
  @spec get_compute(String.t()) :: map()
  def get_compute(tenant_id) do
    get(tenant_id) |> Map.get(:compute, %{})
  end

  @doc "Update compute config for a tenant."
  @spec set_compute(String.t(), map()) :: :ok
  def set_compute(tenant_id, compute) when is_map(compute) do
    GenServer.call(__MODULE__, {:update_key, tenant_id, :compute, compute})
  end

  @doc "Get resource limits for a tenant."
  @spec get_limits(String.t()) :: map()
  def get_limits(tenant_id) do
    get(tenant_id) |> Map.get(:limits, %{})
  end

  @doc "Update resource limits for a tenant."
  @spec set_limits(String.t(), map()) :: :ok
  def set_limits(tenant_id, limits) when is_map(limits) do
    GenServer.call(__MODULE__, {:update_key, tenant_id, :limits, limits})
  end

  @doc "Return the default tenant config."
  @spec default_config() :: map()
  def default_config do
    %{
      compute: %{
        provider: :miosa,
        region: "us-east-1",
        sprite_defaults: %{cpu: 1, memory_gb: 1}
      },
      llm_providers: [
        %{provider: :ollama, api_key: nil, default: true, enabled: true}
      ],
      limits: %{
        max_os_instances: 10,
        max_agents_per_os: 50,
        max_tokens_daily: 1_000_000
      },
      tier_overrides: %{}
    }
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Logger.info("[Tenant.Config] Initialized ETS table")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, tenant_id, config}, _from, state) do
    merged = Map.merge(default_config(), atomize_keys(config))
    :ets.insert(@table, {tenant_id, merged})
    {:reply, :ok, state}
  end

  def handle_call({:update_key, tenant_id, key, value}, _from, state) do
    current = get(tenant_id)
    updated = Map.put(current, key, value)
    :ets.insert(@table, {tenant_id, updated})
    {:reply, :ok, state}
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  rescue
    ArgumentError -> map
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(other), do: other
end
