defmodule OptimalSystemAgent.MCP.Server do
  @moduledoc """
  GenServer managing a single MCP stdio subprocess.

  Lifecycle:
    1. Spawns the subprocess via Port
    2. Sends JSON-RPC `initialize` + `notifications/initialized`
    3. Sends `tools/list` to discover available tools
    4. Accepts `call_tool/3` calls from Client — sends JSON-RPC, awaits response
    5. Restarts on Port exit (handled by DynamicSupervisor restart policy)

  Security:
    - Input validation against tool's inputSchema before dispatch
    - Tool allowlist filtering via config
    - Audit logging for all tool calls

  All JSON-RPC traffic is logged at :debug level.
  """
  use GenServer
  require Logger

  @protocol_version "2024-11-05"
  @init_timeout_ms 10_000
  @tool_call_timeout_ms 30_000

  defstruct [
    :name,
    :port,
    :tools,
    :allowed_tools,
    next_id: 1,
    # pending: %{id => {from, timer_ref}}
    pending: %{},
    # partial line buffer from Port
    buffer: ""
  ]

  # ──────────────────────────────────────────────────────────────── Public API

  @doc """
  Start a server GenServer.

  config keys:
    - :name          — atom or string identifier (e.g. "github")
    - :command       — executable path (e.g. "npx")
    - :args          — list of string args
    - :env           — optional map of env var overrides (supports ${ENV_VAR} interpolation)
    - :allowed_tools — optional list of tool names to expose (nil = all)
  """
  def start_link(config) do
    name = Map.fetch!(config, :name)
    GenServer.start_link(__MODULE__, config, name: via(name))
  end

  @doc "List tools discovered from this server. Returns [] if not yet initialised."
  def list_tools(server_name) do
    try do
      GenServer.call(via(server_name), :list_tools)
    catch
      :exit, _ -> []
    end
  end

  @doc "Call a tool on this server. Validates input against schema. Blocks up to 30 s."
  def call_tool(server_name, tool_name, arguments) do
    try do
      GenServer.call(via(server_name), {:call_tool, tool_name, arguments}, @tool_call_timeout_ms)
    catch
      :exit, _ -> {:error, "MCP server #{server_name} not running"}
    end
  end

  defp via(name), do: {:via, Registry, {OptimalSystemAgent.MCP.Registry, name}}

  # ──────────────────────────────────────────────────────────────── GenServer

  @impl true
  def init(config) do
    name = Map.fetch!(config, :name)
    command = Map.fetch!(config, :command)
    args = Map.get(config, :args, [])
    raw_env = Map.get(config, :env, %{})
    allowed_tools = Map.get(config, :allowed_tools, nil)

    # Interpolate env vars: ${VAR_NAME} -> System.get_env("VAR_NAME")
    env = interpolate_env(raw_env)

    Logger.info("[MCP] Starting server: #{name} (#{command} #{Enum.join(redact_args(args), " ")})")

    case open_port(command, args, env) do
      {:ok, port} ->
        state = %__MODULE__{name: name, port: port, tools: [], allowed_tools: allowed_tools}
        # Drive init in handle_continue so init/1 can return quickly
        {:ok, state, {:continue, :initialize}}

      {:error, reason} ->
        Logger.error("[MCP] Failed to spawn #{name}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:initialize, state) do
    case do_initialize(state) do
      {:ok, new_state} ->
        Logger.info("[MCP] #{state.name} ready — #{length(new_state.tools)} tools")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[MCP] #{state.name} initialisation failed: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    # Filter by allowlist if configured
    filtered = filter_allowed_tools(state.tools, state.allowed_tools)
    {:reply, filtered, state}
  end

  def handle_call({:call_tool, tool_name, arguments}, from, state) do
    # Security: Check if tool is allowed
    allowed = filter_allowed_tools(state.tools, state.allowed_tools)
    tool = Enum.find(allowed, fn t -> t.name == tool_name end)

    cond do
      tool == nil ->
        audit_log(state.name, tool_name, arguments, :blocked, "Tool not found or not allowed")
        {:reply, {:error, "Tool '#{tool_name}' not found or not allowed"}, state}

      # Security: Validate input against schema
      not valid_input?(arguments, tool.input_schema) ->
        audit_log(state.name, tool_name, arguments, :rejected, "Input validation failed")
        {:reply, {:error, "Input validation failed for tool '#{tool_name}'"}, state}

      true ->
        # Valid call — proceed
        audit_log(state.name, tool_name, arguments, :calling, nil)
        
        {id, state} = next_id(state)

        request = %{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => "tools/call",
          "params" => %{"name" => tool_name, "arguments" => arguments}
        }

        send_request(state.port, request)

        timer = Process.send_after(self(), {:timeout, id}, @tool_call_timeout_ms)
        state = put_in(state.pending[id], {from, timer})
        {:noreply, state}
    end
  end

  # Port data — accumulate lines and dispatch complete JSON objects
  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    Logger.debug("[MCP] #{state.name} <<< #{line}")
    state = handle_line(String.trim(line), state)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, partial}}}, %{port: port} = state) do
    # Accumulate partial line — shouldn't happen with {:line, N} but defensive
    {:noreply, %{state | buffer: state.buffer <> partial}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("[MCP] #{state.name} exited with status #{code}")
    # Fail all pending callers
    state = fail_all_pending(state, "MCP server exited (#{code})")
    {:stop, {:mcp_exit, code}, state}
  end

  def handle_info({:timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, "MCP tool call timed out"})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.port && Port.info(state.port) do
      Port.close(state.port)
    end

    :ok
  end

  # ──────────────────────────────────────────────────────────────── Internals

  defp open_port(command, args, env_map) do
    executable = System.find_executable(command) || command

    env_list =
      Enum.map(env_map, fn {k, v} -> {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))} end)

    port_opts =
      [
        :binary,
        :exit_status,
        {:line, 1_048_576},
        {:args, args},
        {:env, env_list},
        :stderr_to_stdout
      ]

    try do
      port = Port.open({:spawn_executable, to_charlist(executable)}, port_opts)
      {:ok, port}
    rescue
      e -> {:error, e}
    end
  end

  # Synchronous init — send initialize, wait for response, send initialized, list tools.
  defp do_initialize(state) do
    {id, state} = next_id(state)

    init_req = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "osa", "version" => "0.2.5"}
      }
    }

    send_request(state.port, init_req)

    case await_response(state.port, id, @init_timeout_ms) do
      {:ok, _result} ->
        # Send initialized notification (no id — no response expected)
        notify = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
        send_request(state.port, notify)

        # Discover tools
        {tid, state} = next_id(state)

        tools_req = %{
          "jsonrpc" => "2.0",
          "id" => tid,
          "method" => "tools/list",
          "params" => %{}
        }

        send_request(state.port, tools_req)

        case await_response(state.port, tid, @init_timeout_ms) do
          {:ok, %{"tools" => tools}} when is_list(tools) ->
            {:ok, %{state | tools: Enum.map(tools, &parse_tool/1)}}

          {:ok, _} ->
            {:ok, %{state | tools: []}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Block until the Port delivers the response for `id` or we time out.
  # Only usable during synchronous init (before async message loop starts).
  defp await_response(port, id, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        trimmed = String.trim(line)
        Logger.debug("[MCP] init <<< #{trimmed}")

        case Jason.decode(trimmed) do
          {:ok, %{"id" => ^id, "result" => result}} ->
            {:ok, result}

          {:ok, %{"id" => ^id, "error" => err}} ->
            {:error, err}

          {:ok, _other} ->
            # Not our id — keep waiting (e.g. server sends a notification first)
            await_response(port, id, timeout)

          {:error, _} ->
            await_response(port, id, timeout)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp handle_line("", state), do: state

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "result" => result}} ->
        dispatch_response(id, {:ok, result}, state)

      {:ok, %{"id" => id, "error" => err}} ->
        msg = Map.get(err, "message", inspect(err))
        dispatch_response(id, {:error, msg}, state)

      {:ok, _notification} ->
        # Notification — no id, no response needed
        state

      {:error, reason} ->
        Logger.debug("[MCP] #{state.name} JSON parse error: #{inspect(reason)} for: #{line}")
        state
    end
  end

  defp dispatch_response(id, reply, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        Logger.debug("[MCP] #{state.name} unexpected response id=#{id}")
        state

      {{from, timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, reply)
        %{state | pending: pending}
    end
  end

  defp fail_all_pending(state, reason) do
    Enum.each(state.pending, fn {_id, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}}
  end

  defp send_request(port, msg) do
    encoded = Jason.encode!(msg)
    Logger.debug("[MCP] >>> #{encoded}")
    Port.command(port, encoded <> "\n")
  end

  defp next_id(state) do
    {state.next_id, %{state | next_id: state.next_id + 1}}
  end

  defp parse_tool(%{"name" => name} = raw) do
    %{
      name: name,
      description: Map.get(raw, "description", ""),
      input_schema: Map.get(raw, "inputSchema", %{})
    }
  end

  defp parse_tool(raw), do: %{name: inspect(raw), description: "", input_schema: %{}}

  # ──────────────────────────────────────────────────────────────── Security

  # Interpolate ${ENV_VAR} patterns in env values
  defp interpolate_env(env_map) when is_map(env_map) do
    Map.new(env_map, fn {k, v} -> {k, interpolate_value(v)} end)
  end

  defp interpolate_value(value) when is_binary(value) do
    Regex.replace(~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/, value, fn _, var_name ->
      case System.get_env(var_name) do
        nil ->
          Logger.warning("[MCP] Env var #{var_name} not found during interpolation")
          ""
        val -> val
      end
    end)
  end

  defp interpolate_value(value), do: value

  # Filter tools by allowlist — nil means allow all
  defp filter_allowed_tools(tools, nil), do: tools

  defp filter_allowed_tools(tools, allowed) when is_list(allowed) do
    allowed_set = MapSet.new(allowed)
    Enum.filter(tools, fn t -> MapSet.member?(allowed_set, t.name) end)
  end

  # Lightweight JSON Schema validation
  defp valid_input?(arguments, schema) when is_map(schema) do
    validate_schema(arguments, schema)
  end

  defp valid_input?(_arguments, _), do: true

  defp validate_schema(value, %{"type" => type} = schema) do
    type_valid?(value, type) and
      required_valid?(value, schema) and
      properties_valid?(value, schema)
  end

  defp validate_schema(_value, _schema), do: true

  defp type_valid?(value, "string") when is_binary(value), do: true
  defp type_valid?(_value, "string"), do: false
  defp type_valid?(value, "number"), do: is_number(value)
  defp type_valid?(value, "integer"), do: is_integer(value)
  defp type_valid?(value, "boolean"), do: is_boolean(value)
  defp type_valid?(value, "array"), do: is_list(value)
  defp type_valid?(value, "object"), do: is_map(value)
  defp type_valid?(value, "null"), do: is_nil(value)
  defp type_valid?(_value, _type), do: true

  defp required_valid?(value, %{"required" => required}) when is_map(value) and is_list(required) do
    Enum.all?(required, fn key -> Map.has_key?(value, key) end)
  end

  defp required_valid?(_value, _schema), do: true

  defp properties_valid?(value, %{"properties" => props}) when is_map(value) and is_map(props) do
    Enum.all?(props, fn {key, prop_schema} ->
      case Map.get(value, key) do
        nil -> true  # Missing optional property is OK
        prop_value -> validate_schema(prop_value, prop_schema) and string_constraints_valid?(prop_value, prop_schema)
      end
    end)
  end

  defp properties_valid?(_value, _schema), do: true

  # Enforce maxLength/minLength on strings when schema specifies them
  defp string_constraints_valid?(value, schema) when is_binary(value) do
    max_ok = case Map.get(schema, "maxLength") do
      nil -> true
      max when is_integer(max) -> String.length(value) <= max
      _ -> true
    end

    min_ok = case Map.get(schema, "minLength") do
      nil -> true
      min when is_integer(min) -> String.length(value) >= min
      _ -> true
    end

    max_ok and min_ok
  end

  defp string_constraints_valid?(_value, _schema), do: true

  @secret_flags ~w[--token --key --secret --password --api-key --apikey]

  defp redact_args(args) when is_list(args) do
    args
    |> Enum.chunk_every(2, 1, [:_end])
    |> Enum.flat_map(fn
      [flag, _val] when is_binary(flag) ->
        if String.downcase(flag) in @secret_flags, do: [flag, "[REDACTED]"], else: [flag]
      [last, :_end] -> [last]
      other -> other
    end)
  end

  defp redact_args(args), do: args

  # Audit logging for forensics
  defp audit_log(server_name, tool_name, arguments, status, reason) do
    args_hash = Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(arguments)), case: :lower)

    log_entry = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      server: server_name,
      tool: sanitize_for_log(tool_name),
      args_hash: args_hash,
      status: status
    }

    log_entry = if reason, do: Map.put(log_entry, :reason, sanitize_for_log(to_string(reason))), else: log_entry
    Logger.info("[MCP Audit] #{inspect(log_entry)}")
  end

  defp sanitize_for_log(value) when is_binary(value) do
    value
    |> String.replace(~r/[\r\n\t]/, " ")
    |> String.slice(0, 128)
  end

  defp sanitize_for_log(value), do: sanitize_for_log(to_string(value))
end
