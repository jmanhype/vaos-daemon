defmodule Daemon.Sandbox.Sprites do
  @moduledoc """
  Sprites.dev sandbox backend — Firecracker microVM-based isolation.

  Wraps the Sprites.dev REST API to create, execute in, checkpoint,
  and destroy lightweight VMs for agent sandbox execution.
  """

  use GenServer
  require Logger

  @behaviour Daemon.Sandbox.Behaviour

  @default_api_url "https://api.sprites.dev"

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Daemon.Sandbox.Behaviour
  def available? do
    token = Application.get_env(:daemon, :sprites_token)
    is_binary(token) and token != ""
  end

  @impl Daemon.Sandbox.Behaviour
  def execute(command, opts \\ []) do
    if available?() do
      GenServer.call(__MODULE__, {:execute, command, opts}, timeout(opts))
    else
      {:error, "Sprites sandbox not available (SPRITES_TOKEN not set)"}
    end
  end

  @doc "Create a new Firecracker microVM sprite."
  def create_sprite(opts \\ []) do
    GenServer.call(__MODULE__, {:create_sprite, opts}, 60_000)
  end

  @doc "Save sprite state to a checkpoint."
  def checkpoint(sprite_id, label \\ "default") do
    GenServer.call(__MODULE__, {:checkpoint, sprite_id, label}, 60_000)
  end

  @doc "Restore sprite from a checkpoint."
  def restore(sprite_id, label \\ "default") do
    GenServer.call(__MODULE__, {:restore, sprite_id, label}, 60_000)
  end

  @doc "Get the sprite's public HTTP preview URL."
  def preview_url(sprite_id) do
    GenServer.call(__MODULE__, {:preview_url, sprite_id})
  end

  @doc "Destroy a sprite."
  def destroy(sprite_id) do
    GenServer.call(__MODULE__, {:destroy, sprite_id})
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %{
      api_url: Application.get_env(:daemon, :sprites_api_url, @default_api_url),
      token: Application.get_env(:daemon, :sprites_token),
      default_sprite: nil
    }

    Logger.info("[Sandbox.Sprites] Initialized — api_url=#{state.api_url}")
    {:ok, state}
  end

  @impl true
  def handle_call({:execute, command, opts}, _from, state) do
    sprite_id = Keyword.get(opts, :sprite_id) || state.default_sprite

    result =
      if sprite_id do
        api_post(state, "/sprites/#{sprite_id}/exec", %{command: command})
      else
        with {:ok, %{"id" => id}} <- api_post(state, "/sprites", build_create_body(opts)),
             exec_result <- api_post(state, "/sprites/#{id}/exec", %{command: command}),
             _ <- api_delete(state, "/sprites/#{id}") do
          exec_result
        end
      end

    reply =
      case result do
        {:ok, %{"output" => output, "exit_code" => code}} -> {:ok, output, code}
        {:ok, %{"output" => output}} -> {:ok, output, 0}
        {:error, reason} -> {:error, reason}
        other -> {:error, "Unexpected Sprites response: #{inspect(other)}"}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:create_sprite, opts}, _from, state) do
    result = api_post(state, "/sprites", build_create_body(opts))

    state =
      case result do
        {:ok, %{"id" => id}} -> %{state | default_sprite: id}
        _ -> state
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:checkpoint, sprite_id, label}, _from, state) do
    result = api_post(state, "/sprites/#{sprite_id}/checkpoint", %{label: label})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:restore, sprite_id, label}, _from, state) do
    result = api_post(state, "/sprites/#{sprite_id}/restore", %{label: label})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:preview_url, sprite_id}, _from, state) do
    result = api_get(state, "/sprites/#{sprite_id}/preview")

    reply =
      case result do
        {:ok, %{"url" => url}} -> {:ok, url}
        other -> other
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:destroy, sprite_id}, _from, state) do
    result = api_delete(state, "/sprites/#{sprite_id}")
    state = if state.default_sprite == sprite_id, do: %{state | default_sprite: nil}, else: state
    {:reply, result, state}
  end

  # ── HTTP helpers ────────────────────────────────────────────────────

  defp api_get(state, path) do
    url = state.api_url <> path

    case Req.get(url, headers: auth_headers(state)) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, "Sprites API #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, "Sprites request failed: #{inspect(reason)}"}
    end
  end

  defp api_post(state, path, body) do
    url = state.api_url <> path

    case Req.post(url, json: body, headers: auth_headers(state)) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, "Sprites API #{status}: #{inspect(resp_body)}"}
      {:error, reason} -> {:error, "Sprites request failed: #{inspect(reason)}"}
    end
  end

  defp api_delete(state, path) do
    url = state.api_url <> path

    case Req.delete(url, headers: auth_headers(state)) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, "Sprites API #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, "Sprites request failed: #{inspect(reason)}"}
    end
  end

  defp auth_headers(%{token: token}) do
    [{"authorization", "Bearer #{token}"}, {"content-type", "application/json"}]
  end

  defp build_create_body(opts) do
    cpu = Keyword.get(opts, :cpu, Application.get_env(:daemon, :sprites_default_cpu, 1))
    memory = Keyword.get(opts, :memory_gb, Application.get_env(:daemon, :sprites_default_memory_gb, 1))
    %{cpu: cpu, memory_gb: memory}
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, 30_000)
end
