defmodule Daemon.Sandbox.Provisioner do
  @moduledoc """
  Template-aware sandbox provisioning using Sprites microVMs.

  Creates, configures, and manages sandboxed OS instances backed by
  Sprites.dev Firecracker VMs with per-template setup and module installation.
  """

  require Logger

  alias Daemon.Sandbox.{Sprites, Registry}

  @templates %{
    business_os: %{
      setup: "mix setup",
      modules: ["crm", "projects", "tasks", "invoices"]
    },
    content_os: %{
      setup: "mix setup",
      modules: ["editor", "publishing", "media"]
    },
    agency_os: %{
      setup: "mix setup",
      modules: ["clients", "projects", "pipeline"]
    },
    dev_os: %{
      setup: "mix setup",
      modules: ["code", "git", "ci", "deploy"]
    },
    data_os: %{
      setup: "mix setup",
      modules: ["ingest", "transform", "visualize"]
    },
    blank: %{
      setup: nil,
      modules: []
    }
  }

  # ── Public API ──────────────────────────────────────────────────────

  @doc "Provision a new sandbox for the given os_id using a template."
  @spec provision(String.t(), atom()) :: {:ok, String.t()} | {:error, term()}
  def provision(os_id, template_type) do
    template = Map.get(@templates, template_type, @templates[:blank])
    Logger.info("[Sandbox.Provisioner] Provisioning os_id=#{os_id} template=#{template_type}")

    with {:ok, %{"id" => sprite_id}} <- Sprites.create_sprite(),
         :ok <- run_setup(sprite_id, template),
         :ok <- install_modules(sprite_id, template.modules),
         {:ok, _} <- Sprites.checkpoint(sprite_id, "initial"),
         :ok <- Registry.register(os_id, sprite_id) do
      Logger.info("[Sandbox.Provisioner] Provisioned os_id=#{os_id} sprite_id=#{sprite_id}")
      {:ok, sprite_id}
    else
      {:error, reason} = err ->
        Logger.error("[Sandbox.Provisioner] Failed to provision os_id=#{os_id}: #{inspect(reason)}")
        err
    end
  end

  @doc "Destroy the sandbox for the given os_id."
  @spec deprovision(String.t()) :: :ok | {:error, term()}
  def deprovision(os_id) do
    case Registry.sprite_lookup(os_id) do
      nil ->
        {:error, "No sandbox registered for os_id=#{os_id}"}

      sprite_id ->
        result = Sprites.destroy(sprite_id)
        Registry.unregister(os_id)
        Logger.info("[Sandbox.Provisioner] Deprovisioned os_id=#{os_id} sprite_id=#{sprite_id}")
        result
    end
  end

  @doc "Return status map for the given os_id."
  @spec status(String.t()) :: {:ok, map()} | {:error, term()}
  def status(os_id) do
    case Registry.sprite_lookup(os_id) do
      nil ->
        {:error, "No sandbox registered for os_id=#{os_id}"}

      sprite_id ->
        {:ok, %{os_id: os_id, sprite_id: sprite_id, status: :running}}
    end
  end

  @doc "Get the preview/console URL for the given os_id."
  @spec console_url(String.t()) :: {:ok, String.t()} | {:error, term()}
  def console_url(os_id) do
    case Registry.sprite_lookup(os_id) do
      nil -> {:error, "No sandbox registered for os_id=#{os_id}"}
      sprite_id -> Sprites.preview_url(sprite_id)
    end
  end

  @doc "List available provisioning templates."
  @spec templates() :: map()
  def templates, do: @templates

  # ── Private helpers ─────────────────────────────────────────────────

  defp run_setup(_sprite_id, %{setup: nil}), do: :ok

  defp run_setup(sprite_id, %{setup: command}) do
    case Sprites.execute(command, sprite_id: sprite_id) do
      {:ok, _output, 0} -> :ok
      {:ok, output, code} -> {:error, "Setup exited #{code}: #{output}"}
      {:error, _} = err -> err
    end
  end

  defp install_modules(_sprite_id, []), do: :ok

  defp install_modules(sprite_id, modules) do
    command = "mix osa.install " <> Enum.join(modules, " ")

    case Sprites.execute(command, sprite_id: sprite_id) do
      {:ok, _output, 0} -> :ok
      {:ok, output, code} -> {:error, "Module install exited #{code}: #{output}"}
      {:error, _} = err -> err
    end
  end
end
