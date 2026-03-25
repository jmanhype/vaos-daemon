defmodule Daemon.Sandbox.Registry do
  @moduledoc """
  ETS-backed registry for sandbox allocations.

  Supports two modes:
  - Agent sandbox allocation: `allocate/2`, `lookup/1`, `release/1` (original API)
  - OS → Sprite mapping: `register/2`, `sprite_lookup/1`, `unregister/1` (command center)
  """

  use GenServer
  require Logger

  @table :sandbox_registry
  @sprite_table :sprite_registry

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── Agent sandbox allocation (original API) ────────────────────────

  @doc "Allocate a sandbox for an agent. Returns `{:ok, allocation}`."
  def allocate(agent_id, opts \\ []) do
    GenServer.call(__MODULE__, {:allocate, agent_id, opts})
  end

  @doc "Look up allocation for an agent. Returns allocation map or nil."
  def lookup(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, allocation}] -> allocation
      [] -> nil
    end
  end

  @doc "Release an agent's sandbox allocation."
  def release(agent_id) do
    :ets.delete(@table, agent_id)
    :ok
  end

  # ── OS → Sprite mapping (command center API) ───────────────────────

  @doc "Register an os_id to sprite_id mapping."
  @spec register(String.t(), String.t()) :: :ok
  def register(os_id, sprite_id) do
    :ets.insert(@sprite_table, {os_id, sprite_id, System.monotonic_time()})
    :ok
  end

  @doc "Look up the sprite_id for a given os_id."
  @spec sprite_lookup(String.t()) :: String.t() | nil
  def sprite_lookup(os_id) do
    case :ets.lookup(@sprite_table, os_id) do
      [{^os_id, sprite_id, _ts}] -> sprite_id
      [] -> nil
    end
  end

  @doc "Remove an os_id → sprite mapping."
  @spec unregister(String.t()) :: :ok
  def unregister(os_id) do
    :ets.delete(@sprite_table, os_id)
    :ok
  end

  @doc "Return all {os_id, sprite_id} tuples."
  @spec all_sprites() :: [{String.t(), String.t()}]
  def all_sprites do
    :ets.tab2list(@sprite_table)
    |> Enum.map(fn {os_id, sprite_id, _ts} -> {os_id, sprite_id} end)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@sprite_table, [:named_table, :set, :public, read_concurrency: true])
    Logger.info("[Sandbox.Registry] Initialized — tables: #{@table}, #{@sprite_table}")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:allocate, agent_id, opts}, _from, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, existing}] ->
        {:reply, {:ok, existing}, state}

      [] ->
        backend = Keyword.get(opts, :backend, :docker)
        allocation = %{
          backend: backend,
          ref: generate_ref(),
          allocated_at: System.monotonic_time()
        }
        :ets.insert(@table, {agent_id, allocation})
        {:reply, {:ok, allocation}, state}
    end
  end

  defp generate_ref do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
