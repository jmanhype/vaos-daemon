defmodule Daemon.Intelligence.RuntimeLedger do
  @moduledoc false

  require Logger

  alias Vaos.Ledger.Epistemic.Ledger, as: EpistemicLedger

  @default_name :decision_runtime_ledger
  @default_prod_path Path.join(System.user_home!(), ".openclaw/decision_runtime_ledger.json")
  @default_test_path Path.join(System.tmp_dir!(), "daemon_decision_runtime_ledger.json")

  def name do
    config()
    |> Keyword.get(:name, @default_name)
  end

  def path do
    config()
    |> Keyword.get(:path, default_path())
  end

  def ensure_started do
    case Process.whereis(name()) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case EpistemicLedger.start_link(path: path(), name: name()) do
          {:ok, _pid} ->
            Logger.info("[RuntimeLedger] Started EpistemicLedger (#{inspect(name())})")
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[RuntimeLedger] Failed to start EpistemicLedger #{inspect(name())}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  rescue
    error ->
      Logger.warning("[RuntimeLedger] Failed to start runtime ledger: #{Exception.message(error)}")
      {:error, :start_failed}
  end

  defp config do
    Application.get_env(:daemon, :decision_runtime_ledger, [])
  end

  defp default_path do
    if Mix.env() == :test do
      @default_test_path
    else
      @default_prod_path
    end
  end
end
