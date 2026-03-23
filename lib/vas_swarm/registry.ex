defmodule VAS.Swarm.Registry do
  @moduledoc """
  Registry for tracking all active VAS agents.

  Maintains a mapping of agent IDs to their PIDs and metadata.
  """

  use GenServer
  require Logger

  @table_name :vas_agent_registry

  #
  # Client API
  #

  @doc """
  Starts the registry.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers an agent with the registry.
  """
  def register(agent_id, pid, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:register, agent_id, pid, metadata})
  end

  @doc """
  Unregisters an agent from the registry.
  """
  def unregister(agent_id) do
    GenServer.call(__MODULE__, {:unregister, agent_id})
  end

  @doc """
  Looks up an agent by ID.
  """
  def lookup(agent_id) do
    GenServer.call(__MODULE__, {:lookup, agent_id})
  end

  @doc """
  Lists all registered agents.
  """
  def list_agents do
    GenServer.call(__MODULE__, :list_agents)
  end

  @doc """
  Gets agent metadata.
  """
  def get_metadata(agent_id) do
    GenServer.call(__MODULE__, {:get_metadata, agent_id})
  end

  @doc """
  Updates agent metadata.
  """
  def update_metadata(agent_id, metadata) do
    GenServer.call(__MODULE__, {:update_metadata, agent_id, metadata})
  end

  #
  # Server Callbacks
  #

  @impl true
  def init(_opts) do
    # Create ETS table for fast lookups
    :ets.new(@table_name, [:named_table, :set, :public])
    Logger.info("VAS Agent Registry started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, agent_id, pid, metadata}, _from, state) do
    :ets.insert(@table_name, {agent_id, pid, metadata})

    # Monitor the process to detect crashes
    Process.monitor(pid)

    Logger.info("Registered agent: #{agent_id}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, agent_id}, _from, state) do
    case :ets.lookup(@table_name, agent_id) do
      [{^agent_id, pid, _metadata}] ->
        :ets.delete(@table_name, agent_id)
        Process.demonitor(pid, [:flush])
        Logger.info("Unregistered agent: #{agent_id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:lookup, agent_id}, _from, state) do
    case :ets.lookup(@table_name, agent_id) do
      [{^agent_id, pid, metadata}] ->
        {:reply, {:ok, pid, metadata}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_agents, _from, state) do
    agents =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {agent_id, _pid, metadata} ->
        Map.put(metadata, :id, agent_id)
      end)

    {:reply, agents, state}
  end

  @impl true
  def handle_call({:get_metadata, agent_id}, _from, state) do
    case :ets.lookup(@table_name, agent_id) do
      [{^agent_id, _pid, metadata}] ->
        {:reply, {:ok, metadata}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update_metadata, agent_id, metadata}, _from, state) do
    case :ets.lookup(@table_name, agent_id) do
      [{^agent_id, pid, _existing_metadata}] ->
        :ets.insert(@table_name, {agent_id, pid, metadata})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Find and unregister the crashed agent
    agent_id =
      :ets.tab2list(@table_name)
      |> Enum.find(fn {_id, registered_pid, _metadata} -> registered_pid == pid end)
      |> case do
        {id, _pid, _metadata} -> id
        nil -> nil
      end

    if agent_id do
      :ets.delete(@table_name, agent_id)
      Logger.warning("Agent #{agent_id} crashed: #{inspect(reason)}")
    end

    {:noreply, state}
  end
end
