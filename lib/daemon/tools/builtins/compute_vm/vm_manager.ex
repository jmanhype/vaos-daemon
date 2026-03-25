defmodule Daemon.Tools.Builtins.ComputeVm.VmManager do
  @moduledoc """
  GenServer that tracks active VMs per agent session.

  Responsibilities:
  - Track which VMs were created by which session
  - Auto-destroy VMs when a session terminates (via Process.monitor)
  - Provide a registry lookup for vm_id → session_id
  - Emit telemetry events for VM lifecycle

  ## Usage

      # Register a VM for the current session
      VmManager.register(session_id, vm_id)

      # List all VMs for a session
      VmManager.list_by_session(session_id)

      # Mark a VM as destroyed (removes from tracking)
      VmManager.unregister(vm_id)

  When the session process dies, all its VMs are automatically destroyed
  via the compute API.
  """

  use GenServer

  require Logger

  alias Daemon.Tools.Builtins.ComputeVm

  @name __MODULE__

  # ── Public API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Register a VM as belonging to a session process."
  @spec register(pid() | String.t(), String.t()) :: :ok
  def register(session_pid_or_id, vm_id) do
    GenServer.cast(@name, {:register, session_pid_or_id, vm_id})
  end

  @doc "Unregister a VM (called after explicit destroy)."
  @spec unregister(String.t()) :: :ok
  def unregister(vm_id) do
    GenServer.cast(@name, {:unregister, vm_id})
  end

  @doc "List all VM IDs registered to a session."
  @spec list_by_session(pid() | String.t()) :: [String.t()]
  def list_by_session(session_pid_or_id) do
    GenServer.call(@name, {:list_by_session, session_pid_or_id})
  end

  @doc "Return the full tracking state (for diagnostics)."
  @spec state() :: map()
  def state do
    GenServer.call(@name, :state)
  end

  # ── GenServer callbacks ───────────────────────────────────────────

  @impl true
  def init(_opts) do
    # vms: %{vm_id => %{session_key: term, monitored_pid: pid | nil}}
    # sessions: %{session_key => [vm_id]}
    # monitors: %{monitor_ref => session_key}
    {:ok, %{vms: %{}, sessions: %{}, monitors: %{}}}
  end

  @impl true
  def handle_cast({:register, session_key, vm_id}, state) do
    # If session_key is a live PID we monitor it for auto-cleanup.
    {monitored_pid, new_state} =
      if is_pid(session_key) and Process.alive?(session_key) do
        # Only set up a monitor if we haven't monitored this pid yet
        already_monitored? =
          Enum.any?(state.monitors, fn {_ref, k} -> k == session_key end)

        if already_monitored? do
          {session_key, state}
        else
          ref = Process.monitor(session_key)
          monitors = Map.put(state.monitors, ref, session_key)
          {session_key, %{state | monitors: monitors}}
        end
      else
        {nil, state}
      end

    # Track the VM
    vm_entry = %{session_key: session_key, monitored_pid: monitored_pid}
    vms = Map.put(new_state.vms, vm_id, vm_entry)

    session_vms = Map.get(new_state.sessions, session_key, [])
    sessions = Map.put(new_state.sessions, session_key, [vm_id | session_vms])

    Logger.debug("[VmManager] Registered vm=#{vm_id} for session=#{inspect(session_key)}")

    {:noreply, %{new_state | vms: vms, sessions: sessions}}
  end

  @impl true
  def handle_cast({:unregister, vm_id}, state) do
    case Map.get(state.vms, vm_id) do
      nil ->
        {:noreply, state}

      %{session_key: session_key} ->
        vms = Map.delete(state.vms, vm_id)

        session_vms = Map.get(state.sessions, session_key, []) |> List.delete(vm_id)

        sessions =
          if session_vms == [] do
            Map.delete(state.sessions, session_key)
          else
            Map.put(state.sessions, session_key, session_vms)
          end

        Logger.debug("[VmManager] Unregistered vm=#{vm_id}")
        {:noreply, %{state | vms: vms, sessions: sessions}}
    end
  end

  @impl true
  def handle_call({:list_by_session, session_key}, _from, state) do
    {:reply, Map.get(state.sessions, session_key, []), state}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      session_key ->
        monitors = Map.delete(state.monitors, ref)
        vm_ids = Map.get(state.sessions, session_key, [])

        Logger.info(
          "[VmManager] Session #{inspect(session_key)} exited (#{inspect(reason)}) — " <>
            "auto-destroying #{length(vm_ids)} VM(s): #{inspect(vm_ids)}"
        )

        # Destroy each VM asynchronously so we don't block
        Enum.each(vm_ids, fn vm_id ->
          Task.start(fn ->
            case ComputeVm.execute(%{"operation" => "destroy", "vm_id" => vm_id}) do
              {:ok, msg} ->
                Logger.info("[VmManager] Auto-destroyed vm=#{vm_id}: #{msg}")

              {:error, err} ->
                Logger.warning(
                  "[VmManager] Failed to auto-destroy vm=#{vm_id}: #{err}"
                )
            end
          end)
        end)

        vms =
          Enum.reduce(vm_ids, state.vms, fn vm_id, acc -> Map.delete(acc, vm_id) end)

        sessions = Map.delete(state.sessions, session_key)

        {:noreply, %{state | vms: vms, sessions: sessions, monitors: monitors}}
    end
  end
end
