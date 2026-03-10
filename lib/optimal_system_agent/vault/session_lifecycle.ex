defmodule OptimalSystemAgent.Vault.SessionLifecycle do
  @moduledoc """
  Session lifecycle orchestration: wake, sleep, checkpoint, recover.

  Manages dirty-death detection via flag files:
  - On wake: check for dirty flags from previous sessions
  - On checkpoint: touch dirty flag
  - On clean sleep: remove dirty flag + create handoff
  - On crash: dirty flag remains for next wake to detect
  """
  require Logger

  alias OptimalSystemAgent.Vault.{Store, Handoff, Observer}

  @doc "Wake — called at session start."
  @spec wake(String.t()) :: {:ok, :clean | :recovered}
  def wake(session_id) do
    dirty_dir = dirty_dir()
    File.mkdir_p!(dirty_dir)

    # Check for dirty flags from previous sessions
    recovery = check_dirty_deaths(session_id)

    # Set dirty flag for this session
    touch_dirty(session_id)

    Logger.info(
      "[vault/lifecycle] Session #{session_id} woke (#{if recovery == [], do: "clean", else: "recovered #{length(recovery)} sessions"})"
    )

    if recovery == [] do
      {:ok, :clean}
    else
      {:ok, :recovered}
    end
  end

  @doc "Sleep — called at clean session end."
  @spec sleep(String.t(), map()) :: :ok
  def sleep(session_id, context \\ %{}) do
    # Flush observer buffer
    Observer.flush()

    # Create handoff document
    case Handoff.create(session_id, context) do
      {:ok, path} -> Logger.info("[vault/lifecycle] Handoff created: #{path}")
      {:error, reason} -> Logger.warning("[vault/lifecycle] Handoff failed: #{inspect(reason)}")
    end

    # Clear dirty flag
    clear_dirty(session_id)

    Logger.info("[vault/lifecycle] Session #{session_id} sleeping cleanly")
    :ok
  end

  @doc "Checkpoint — mid-session save point."
  @spec checkpoint(String.t()) :: :ok
  def checkpoint(session_id) do
    # Flush observer
    Observer.flush()

    # Touch dirty flag (refresh timestamp)
    touch_dirty(session_id)

    Logger.debug("[vault/lifecycle] Checkpoint for session #{session_id}")
    :ok
  end

  @doc "Recover — called when dirty deaths are detected."
  @spec recover(String.t()) :: {:ok, map()} | :none
  def recover(session_id) do
    case Handoff.load_for_session(session_id) do
      {:ok, content} ->
        clear_dirty(session_id)
        {:ok, %{session_id: session_id, handoff: content}}

      :none ->
        clear_dirty(session_id)
        :none
    end
  end

  # --- Private ---

  defp dirty_dir do
    Path.join([Store.vault_root(), ".vault", "dirty"])
  end

  defp touch_dirty(session_id) do
    path = Path.join(dirty_dir(), session_id)
    File.write(path, DateTime.utc_now() |> DateTime.to_iso8601())
  end

  defp clear_dirty(session_id) do
    path = Path.join(dirty_dir(), session_id)
    File.rm(path)
  end

  defp check_dirty_deaths(current_session_id) do
    dir = dirty_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.reject(&(&1 == current_session_id))
        |> Enum.map(fn file ->
          Logger.warning("[vault/lifecycle] Dirty death detected: session #{file}")
          recover(file)
          file
        end)

      _ ->
        []
    end
  end
end
