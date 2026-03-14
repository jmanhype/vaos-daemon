defmodule OptimalSystemAgent.Tools.Synthesizer do
  @moduledoc """
  Zero-Shot Tool Synthesis — writes and hot-loads generated tool modules at runtime.

  `synthesize/2` takes a tool name and a spec map, generates Elixir source for
  a module implementing MiosaTools.Behaviour, writes it to ~/.osa/tools/<name>.ex,
  evaluates it into the running VM (no restart required), and optionally triggers
  a skills reload so the new tool appears in tool listings immediately.

  Generated modules live under `OptimalSystemAgent.Tools.Generated.<CamelName>`.
  """
  use GenServer
  require Logger

  @tools_subdir "tools"

  # ── Public API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Synthesize a new tool module from `spec` and hot-load it.

  `name`  - kebab-case tool name string (used as file name and tool identifier)
  `spec`  - map with keys:
    - "description" (string)  — what the tool does
    - "params"      (list)    — list of param name strings
    - "body"        (string)  — Elixir code for the execute function body

  Returns `{:ok, module_name_string}` or `{:error, reason}`.
  """
  @spec synthesize(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def synthesize(name, spec) when is_binary(name) and is_map(spec) do
    GenServer.call(__MODULE__, {:synthesize, name, spec}, 30_000)
  end

  @doc "List names of synthesized tools (from ~/.osa/tools/)."
  @spec list_synthesized() :: [String.t()]
  def list_synthesized do
    GenServer.call(__MODULE__, :list_synthesized)
  end

  @doc "Delete a synthesized tool file by name. Returns :ok or {:error, reason}."
  @spec delete_synthesized(String.t()) :: :ok | {:error, term()}
  def delete_synthesized(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:delete_synthesized, name})
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:synthesize, name, spec}, _from, state) do
    result = do_synthesize(name, spec)
    {:reply, result, state}
  end

  def handle_call(:list_synthesized, _from, state) do
    tools = do_list_synthesized()
    {:reply, tools, state}
  end

  def handle_call({:delete_synthesized, name}, _from, state) do
    result = do_delete_synthesized(name)
    {:reply, result, state}
  end

  def handle_call(msg, _from, state) do
    Logger.warning("[Synthesizer] Unexpected call: #{inspect(msg)}")
    {:reply, {:error, :unknown_call}, state}
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp tools_dir do
    base = Application.get_env(:optimal_system_agent, :osa_home, "~/.osa")
    Path.join(Path.expand(base), @tools_subdir)
  end

  defp do_synthesize(name, spec) do
    description = Map.get(spec, "description", "")
    params = Map.get(spec, "params", [])
    body = Map.get(spec, "body", "")

    with :ok <- validate_spec(description, params, body),
         camel_name = name |> String.replace("-", "_") |> Macro.camelize(),
         module_name = "OptimalSystemAgent.Tools.Generated.#{camel_name}",
         source = generate_source(name, description, params, body, camel_name),
         :ok <- write_source(name, source),
         :ok <- eval_source(source, name) do
      reload_registry()
      Logger.info("[Synthesizer] Tool '#{name}' synthesized as #{module_name}")
      {:ok, module_name}
    end
  end

  defp validate_spec(description, params, body) do
    cond do
      not is_binary(description) ->
        {:error, "description must be a string"}

      not is_list(params) ->
        {:error, "params must be a list of strings"}

      not Enum.all?(params, &is_binary/1) ->
        {:error, "all params must be strings"}

      not is_binary(body) or String.trim(body) == "" ->
        {:error, "body must be a non-empty string"}

      true ->
        :ok
    end
  end

  defp generate_source(name, description, params, body, camel_name) do
    params_atoms = params |> Enum.map(fn p -> ":#{p}" end) |> Enum.join(", ")

    """
    defmodule OptimalSystemAgent.Tools.Generated.#{camel_name} do
      @moduledoc "Generated tool: #{name}"
      @behaviour MiosaTools.Behaviour

      @impl true
      def name, do: "#{name}"

      @impl true
      def description, do: "#{escape_string(description)}"

      def params, do: [#{params_atoms}]

      @impl true
      def parameters do
        properties =
          Enum.reduce([#{params_atoms}], %{}, fn param, acc ->
            Map.put(acc, Atom.to_string(param), %{"type" => "string", "description" => Atom.to_string(param)})
          end)
        %{
          "type" => "object",
          "properties" => properties,
          "required" => [#{params |> Enum.map(fn p -> "\"#{p}\"" end) |> Enum.join(", ")}]
        }
      end

      @impl true
      def safety, do: :write_safe

      @impl true
      def available?, do: true

      @impl true
      def execute(params) do
        #{indent_body(body)}
      end
    end
    """
  end

  defp escape_string(s) when is_binary(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "")
  end

  defp indent_body(body) do
    # Indent the body by 8 spaces (4 + 4 for execute function)
    body
    |> String.split("\n")
    |> Enum.join("\n        ")
  end

  defp write_source(name, source) do
    dir = tools_dir()

    case File.mkdir_p(dir) do
      :ok ->
        path = Path.join(dir, "#{name}.ex")

        case File.write(path, source) do
          :ok ->
            Logger.debug("[Synthesizer] Wrote source to #{path}")
            :ok

          {:error, reason} ->
            Logger.error("[Synthesizer] Failed to write #{path}: #{inspect(reason)}")
            {:error, "failed to write file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("[Synthesizer] Failed to create tools dir #{dir}: #{inspect(reason)}")
        {:error, "failed to create tools directory: #{inspect(reason)}"}
    end
  end

  defp eval_source(source, name) do
    Code.eval_string(source)
    Logger.debug("[Synthesizer] Evaluated module for '#{name}'")
    :ok
  rescue
    e ->
      reason = Exception.message(e)
      Logger.error("[Synthesizer] Code.eval_string failed for '#{name}': #{reason}")
      {:error, "compilation failed: #{reason}"}
  end

  defp reload_registry do
    try do
      OptimalSystemAgent.Tools.Registry.reload_skills()
    catch
      :exit, _ -> :ok
    rescue
      _ -> :ok
    end
  end

  defp do_list_synthesized do
    dir = tools_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(fn entry ->
        String.ends_with?(entry, ".ex") or File.dir?(Path.join(dir, entry))
      end)
      |> Enum.map(fn entry ->
        entry
        |> String.replace_suffix(".ex", "")
      end)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[Synthesizer] list_synthesized error: #{inspect(e)}")
      []
  end

  defp do_delete_synthesized(name) do
    path = Path.join(tools_dir(), "#{name}.ex")

    if File.exists?(path) do
      case File.rm(path) do
        :ok ->
          Logger.info("[Synthesizer] Deleted tool '#{name}' at #{path}")
          :ok

        {:error, reason} ->
          Logger.error("[Synthesizer] Failed to delete #{path}: #{inspect(reason)}")
          {:error, "failed to delete file: #{inspect(reason)}"}
      end
    else
      {:error, :not_found}
    end
  end
end
