defmodule Daemon.MCP.Client do
  @moduledoc """
  MCP client orchestrator — reads ~/.daemon/mcp.json and manages one
  `MCP.Server` GenServer per configured stdio server.

  Public surface:
    - `start_servers/0`  — spawn all configured servers under MCP.Supervisor
    - `list_tools/0`     — aggregate tools from every running server
    - `call_tool/2`      — route a tool call to the owning server
    - `stop_servers/0`   — gracefully terminate all running servers

  Config format (standard MCP JSON):
  ```json
  {
    "mcpServers": {
      "filesystem": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"]
      },
      "github": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-github"],
        "env": { "GITHUB_TOKEN": "..." }
      }
    }
  }
  ```
  """
  require Logger

  alias Daemon.MCP.Server

  defp mcp_config_path do
    Application.get_env(:daemon, :mcp_config_path, "~/.daemon/mcp.json")
    |> Path.expand()
  end

  @doc "Load raw server configs from ~/.daemon/mcp.json. Returns a map of name → config."
  def load_servers do
    path = mcp_config_path()

    if File.exists?(path) do
      case Jason.decode(File.read!(path)) do
        {:ok, %{"mcpServers" => servers}} when is_map(servers) ->
          Logger.info("[MCP] Loaded #{map_size(servers)} server configs from #{path}")
          servers

        _ ->
          Logger.debug("[MCP] No valid mcpServers in #{path}")
          %{}
      end
    else
      %{}
    end
  end

  @doc """
  Start all configured MCP servers under `Daemon.MCP.Supervisor`.

  Skips servers that fail to start so one broken config doesn't kill the rest.
  
  Config supports:
    - `command` — executable path
    - `args` — list of string arguments
    - `env` — map of env vars (supports `${ENV_VAR}` interpolation)
    - `allowed_tools` — optional list of tool names to expose (omit for all)
  """
  def start_servers do
    servers = load_servers()

    Enum.each(servers, fn {name, config} ->
      child_config = %{
        name: name,
        command: Map.get(config, "command", ""),
        args: Map.get(config, "args", []),
        env: Map.get(config, "env", %{}),
        allowed_tools: Map.get(config, "allowed_tools", nil)
      }

      spec = {Server, child_config}

      case DynamicSupervisor.start_child(Daemon.MCP.Supervisor, spec) do
        {:ok, _pid} ->
          Logger.info("[MCP] Started server: #{name}")

        {:error, {:already_started, _}} ->
          Logger.debug("[MCP] Server already running: #{name}")

        {:error, reason} ->
          Logger.warning("[MCP] Failed to start server #{name}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc "Aggregate tools from all running MCP servers."
  @spec list_tools() :: list(map())
  def list_tools do
    running_server_names()
    |> Enum.flat_map(fn name ->
      name
      |> Server.list_tools()
      |> Enum.map(fn tool -> Map.put(tool, :server, name) end)
    end)
  end

  @doc """
  Route a tool call to the server that owns it.

  Searches running servers for a tool matching `tool_name`, then delegates
  to `MCP.Server.call_tool/3`.
  """
  @spec call_tool(String.t(), map()) :: {:ok, any()} | {:error, String.t()}
  def call_tool(tool_name, arguments) do
    case find_server_for_tool(tool_name) do
      nil ->
        {:error, "No MCP server found for tool: #{tool_name}"}

      server_name ->
        Server.call_tool(server_name, tool_name, arguments)
    end
  end

  @doc "Gracefully terminate all running MCP server processes."
  def stop_servers do
    running_server_names()
    |> Enum.each(fn name ->
      case GenServer.whereis({:via, Registry, {Daemon.MCP.Registry, name}}) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Daemon.MCP.Supervisor, pid)
      end
    end)

    :ok
  end

  # ──────────────────────────────────────────────────────────────── Internals

  defp running_server_names do
    Registry.select(Daemon.MCP.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  rescue
    _ -> []
  end

  defp find_server_for_tool(tool_name) do
    running_server_names()
    |> Enum.find(fn name ->
      name
      |> Server.list_tools()
      |> Enum.any?(fn t -> t.name == tool_name end)
    end)
  end
end
