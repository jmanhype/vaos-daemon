defmodule Daemon.Production.ChromeSlot do
  @moduledoc """
  Gates Chrome browser access to a single concurrent user.

  Only one session may hold the Chrome slot at a time. The slot auto-releases
  after 10 minutes as a safety net against leaked locks.

  ## Usage

      case ChromeSlot.acquire(session_id) do
        :ok -> # you have the slot
        {:error, :busy} -> # someone else has it
      end

      ChromeSlot.release(session_id)
  """
  use GenServer

  require Logger

  @timeout_ms :timer.minutes(10)

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Acquire the Chrome slot for the given session. Returns :ok or {:error, :busy}."
  @spec acquire(String.t()) :: :ok | {:error, :busy}
  def acquire(session_id \\ "default") do
    GenServer.call(__MODULE__, {:acquire, session_id})
  end

  @doc "Release the Chrome slot. Only the holder can release."
  @spec release(String.t()) :: :ok | {:error, :not_holder}
  def release(session_id \\ "default") do
    GenServer.call(__MODULE__, {:release, session_id})
  end

  @doc "Check current slot status."
  @spec status() :: :free | {:held, String.t(), non_neg_integer()}
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{holder: nil, timer_ref: nil}}
  end

  @impl true
  def handle_call({:acquire, session_id}, _from, %{holder: nil} = state) do
    timer_ref = Process.send_after(self(), {:auto_release, session_id}, @timeout_ms)
    Logger.info("[ChromeSlot] Acquired by #{session_id}")
    {:reply, :ok, %{state | holder: session_id, timer_ref: timer_ref}}
  end

  def handle_call({:acquire, session_id}, _from, %{holder: session_id} = state) do
    # Re-entrant: same session already holds it
    {:reply, :ok, state}
  end

  def handle_call({:acquire, _session_id}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:release, session_id}, _from, %{holder: session_id} = state) do
    cancel_timer(state.timer_ref)
    Logger.info("[ChromeSlot] Released by #{session_id}")
    {:reply, :ok, %{state | holder: nil, timer_ref: nil}}
  end

  def handle_call({:release, _session_id}, _from, state) do
    {:reply, {:error, :not_holder}, state}
  end

  def handle_call(:status, _from, %{holder: nil} = state) do
    {:reply, :free, state}
  end

  def handle_call(:status, _from, %{holder: holder} = state) do
    {:reply, {:held, holder, remaining_ms(state.timer_ref)}, state}
  end

  @impl true
  def handle_info({:auto_release, session_id}, %{holder: session_id} = state) do
    Logger.warning("[ChromeSlot] Auto-released (timeout) for #{session_id}")
    {:noreply, %{state | holder: nil, timer_ref: nil}}
  end

  def handle_info({:auto_release, _session_id}, state) do
    # Stale timer for a session that already released — ignore
    {:noreply, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp remaining_ms(nil), do: 0

  defp remaining_ms(ref) do
    case Process.read_timer(ref) do
      false -> 0
      ms -> ms
    end
  end
end
