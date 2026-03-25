defmodule Daemon.Sandbox.Config do
  @moduledoc """
  Sandbox security configuration.

  All settings are read from Application config (set in config/config.exs or via
  environment variables at runtime). The sandbox is **disabled by default** — set
  DAEMON_SANDBOX_ENABLED=true or `sandbox_enabled: true` in config to activate it.
  """

  require Logger

  @enforce_keys []
  defstruct [
    # Master switch — false by default (opt-in)
    enabled: false,
    # :docker | :beam | :wasm | :sprites (process-only fallback)
    mode: :docker,
    # Allow network access inside container
    network: false,
    # Memory limit (Docker --memory flag)
    max_memory: "256m",
    # CPU limit — 0.5 = half a core (Docker --cpus flag)
    max_cpu: "0.5",
    # Execution timeout in milliseconds
    timeout: 30_000,
    # Mount ~/.daemon/workspace into container as /workspace
    workspace_mount: true,
    # Container image to use
    image: "osa-sandbox:latest",
    # Images that callers are permitted to request
    allowed_images: ["osa-sandbox:latest", "python:3.12-slim", "node:22-slim"],
    # Linux capabilities to drop inside container
    capabilities_drop: ["ALL"],
    # Capabilities to add back after dropping ALL (default: none)
    capabilities_add: [],
    # Mount the container root filesystem read-only
    read_only_root: true,
    # Prevent privilege escalation via setuid/setgid
    no_new_privileges: true,
    # Sprites.dev settings
    sprites_token: nil,
    sprites_api_url: "https://api.sprites.dev",
    sprites_default_cpu: 1,
    sprites_default_memory_gb: 1
  ]

  @type t :: %__MODULE__{
          enabled: boolean(),
          mode: :docker | :beam | :wasm | :sprites,
          network: boolean(),
          max_memory: String.t(),
          max_cpu: String.t(),
          timeout: pos_integer(),
          workspace_mount: boolean(),
          image: String.t(),
          allowed_images: [String.t()],
          capabilities_drop: [String.t()],
          capabilities_add: [String.t()],
          read_only_root: boolean(),
          no_new_privileges: boolean(),
          sprites_token: String.t() | nil,
          sprites_api_url: String.t(),
          sprites_default_cpu: pos_integer(),
          sprites_default_memory_gb: pos_integer()
        }

  @doc """
  Build a Config struct from the application environment.

  All keys have safe defaults so `from_config/0` never raises.
  """
  @spec from_config() :: t()
  def from_config do
    app = :daemon

    enabled =
      case Application.get_env(app, :sandbox_enabled, false) do
        true -> true
        "true" -> true
        _ -> false
      end

    mode =
      case Application.get_env(app, :sandbox_mode, :docker) do
        :beam -> :beam
        "beam" -> :beam
        :wasm -> :wasm
        "wasm" -> :wasm
        :sprites -> :sprites
        "sprites" -> :sprites
        _ -> :docker
      end

    network =
      case Application.get_env(app, :sandbox_network, false) do
        true -> true
        "true" -> true
        _ -> false
      end

    config = %__MODULE__{
      enabled: enabled,
      mode: mode,
      network: network,
      max_memory: Application.get_env(app, :sandbox_max_memory, "256m"),
      max_cpu: Application.get_env(app, :sandbox_max_cpu, "0.5"),
      timeout: Application.get_env(app, :sandbox_timeout, 30_000),
      workspace_mount: Application.get_env(app, :sandbox_workspace_mount, true),
      image: Application.get_env(app, :sandbox_image, "osa-sandbox:latest"),
      allowed_images:
        Application.get_env(app, :sandbox_allowed_images, [
          "osa-sandbox:latest",
          "python:3.12-slim",
          "node:22-slim"
        ]),
      capabilities_drop: Application.get_env(app, :sandbox_capabilities_drop, ["ALL"]),
      capabilities_add: Application.get_env(app, :sandbox_capabilities_add, []),
      read_only_root: Application.get_env(app, :sandbox_read_only_root, true),
      no_new_privileges: Application.get_env(app, :sandbox_no_new_privileges, true),
      sprites_token: Application.get_env(app, :sprites_token),
      sprites_api_url: Application.get_env(app, :sprites_api_url, "https://api.sprites.dev"),
      sprites_default_cpu: Application.get_env(app, :sprites_default_cpu, 1),
      sprites_default_memory_gb: Application.get_env(app, :sprites_default_memory_gb, 1)
    }

    if config.enabled do
      Logger.debug("[Sandbox.Config] Sandbox enabled — mode=#{config.mode} image=#{config.image}")
    end

    config
  end

  @doc """
  Returns true when `image` is in the allow-list.
  """
  @spec image_allowed?(t(), String.t()) :: boolean()
  def image_allowed?(%__MODULE__{allowed_images: allowed}, image) do
    image in allowed
  end
end
