defmodule OptimalSystemAgent.Providers.Ollama do
  @moduledoc """
  Ollama local LLM provider.

  Connects to a locally-running Ollama instance. No API key required.
  Supports tool/function calling for models that expose it.

  At boot, auto-detects the best installed model (prefers larger, tool-capable models).
  Only sends tools to models ≥ 14B parameters to avoid hallucinated tool calls.

  Config keys:
    :ollama_url   — base URL (default: http://localhost:11434)
    :ollama_model — model name (default: auto-detected or llama3.2:latest)
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Providers.ToolCallParsers
  alias OptimalSystemAgent.Utils.Text

  # Models known to handle tool calling well (name prefix → min size in GB)
  # Include both hyphenated and non-hyphenated variants (glm-4 AND glm4)
  @tool_capable_prefixes ~w(qwen3 qwen2.5 llama3.3 llama3.1 gemma3 glm-4 glm4 mistral mixtral deepseek command-r kimi minimax)

  # Minimum model size (in bytes) to enable tool calling — ~14B params ≈ 8GB on disk
  @tool_min_size 7_000_000_000

  @impl true
  def name, do: :ollama

  @impl true
  def default_model do
    # Return whatever auto-detect found, not a hardcoded small model
    Application.get_env(:optimal_system_agent, :ollama_model, "llama3.2:latest")
  end

  @doc """
  Auto-detect the best available Ollama model and set it as the active model.
  Called at application boot when provider is :ollama and no explicit model override.
  Prefers larger, tool-capable models.
  """
  @spec auto_detect_model() :: :ok
  def auto_detect_model do
    explicit = Application.get_env(:optimal_system_agent, :default_model)

    if explicit && explicit != "" do
      Logger.info("[Ollama] Using explicitly configured model: #{explicit}")
      Application.put_env(:optimal_system_agent, :ollama_model, explicit)
      :ok
    else
      url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

      case list_models(url) do
        {:ok, models} ->
          best = pick_best_model(models)

          if best do
            current = Application.get_env(:optimal_system_agent, :ollama_model, default_model())

            if best.name != current do
              Logger.info(
                "[Ollama] Auto-selected model: #{best.name} (#{Float.round(best.size / 1.0e9, 1)} GB)"
              )

              Application.put_env(:optimal_system_agent, :ollama_model, best.name)
            end
          end

          :ok

        {:error, _} ->
          :ok
      end
    end
  end

  @doc "List models available on the Ollama server."
  @spec list_models(String.t()) :: {:ok, list(map())} | {:error, term()}
  def list_models(url \\ nil) do
    url = url || Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    case Req.get("#{url}/api/tags", [{:receive_timeout, 5_000}] ++ auth_headers()) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        parsed =
          Enum.map(models, fn m ->
            %{name: m["name"], size: m["size"] || 0, modified: m["modified_at"]}
          end)

        {:ok, parsed}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def chat(messages, opts \\ []) do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :ollama_model, default_model())

    body =
      %{
        model: model,
        messages: format_messages(messages),
        stream: false,
        keep_alive: "30m",
        options: %{temperature: Keyword.get(opts, :temperature, 0.7)}
      }
      |> maybe_add_tools(model, opts)
      |> maybe_add_think(model, opts)

    # 600 s — thinking models (kimi-k2.5) need up to ~300 s before producing
    # any output; 120 s was too short and caused Cortex synthesis timeouts.
    req_opts = [json: body, receive_timeout: 600_000] ++ auth_headers()

    try do
      case Req.post("#{url}/api/chat", req_opts) do
        {:ok, %{status: 200, body: %{"message" => %{"content" => content} = msg}}} ->
          tool_calls = parse_tool_calls(msg, model)
          {:ok, %{content: Text.strip_thinking_tokens(content || ""), tool_calls: tool_calls}}

        {:ok, %{status: status, body: resp_body}} ->
          Logger.warning("Ollama returned #{status}: #{inspect(resp_body)}")
          {:error, "Ollama returned #{status}: #{inspect(resp_body)}"}

        {:error, reason} ->
          Logger.error("Ollama connection failed: #{inspect(reason)}")
          {:error, "Ollama connection failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Ollama unexpected error: #{Exception.message(e)}")
        {:error, "Ollama unexpected error: #{Exception.message(e)}"}
    end
  end

  @impl true
  def chat_stream(messages, callback, opts \\ []) do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :ollama_model, default_model())

    body =
      %{
        model: model,
        messages: format_messages(messages),
        stream: true,
        keep_alive: "30m",
        options: %{temperature: Keyword.get(opts, :temperature, 0.7)}
      }
      |> maybe_add_tools(model, opts)
      |> maybe_add_think(model, opts)

    # 600 s per-chunk read timeout — slow local CPU models and long thinking
    # phases (kimi-k2.5 takes ~300 s) need more than the default 300 s.
    req_opts = [json: body, receive_timeout: 600_000, into: :self] ++ auth_headers()

    try do
      case Req.post("#{url}/api/chat", req_opts) do
        {:ok, resp} ->
          collect_stream(resp, callback, %{buffer: "", content: "", tool_calls: []})

        {:error, reason} ->
          Logger.error("Ollama stream connection failed: #{inspect(reason)}")
          {:error, "Ollama stream connection failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Ollama stream unexpected error: #{Exception.message(e)}")
        {:error, "Ollama stream unexpected error: #{Exception.message(e)}"}
    end
  end

  # --- Private ---

  defp pick_best_model(models) do
    # Filter to tool-capable models (by prefix + size), sort by size descending
    tool_capable =
      models
      |> Enum.filter(fn m ->
        name = String.downcase(m.name)

        m.size >= @tool_min_size and
          Enum.any?(@tool_capable_prefixes, &String.starts_with?(name, &1))
      end)
      |> Enum.sort_by(& &1.size, :desc)

    case tool_capable do
      [best | _] ->
        best

      [] ->
        # Fallback: just pick the largest model ≥ 4GB
        models
        |> Enum.filter(fn m -> m.size >= 4_000_000_000 end)
        |> Enum.sort_by(& &1.size, :desc)
        |> List.first()
    end
  end

  @doc """
  Check if a model name matches known tool-capable prefixes.
  Returns true for models that can handle function/tool calling reliably.
  """
  @spec model_supports_tools?(String.t()) :: boolean()
  def model_supports_tools?(model_name) do
    name = String.downcase(model_name)

    Enum.any?(@tool_capable_prefixes, &String.starts_with?(name, &1)) and
      not String.contains?(name, ":1.") and
      not String.contains?(name, ":3b")
  end

  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} ->
        %{"role" => to_string(role), "content" => to_string(content)}

      %{"role" => _} = msg ->
        msg

      msg when is_map(msg) ->
        msg
    end)
  end

  defp maybe_add_tools(body, model, opts) do
    case Keyword.get(opts, :tools) do
      nil ->
        body

      [] ->
        body

      tools ->
        if model_supports_tools?(model) do
          Map.put(body, :tools, format_tools(tools))
        else
          Logger.debug("[Ollama] Skipping tools for #{model} (too small / not tool-capable)")
          body
        end
    end
  end

  # Controls the `think` field for Ollama reasoning models (kimi, qwen3 thinking, etc.)
  # Default: disabled for known thinking models to prevent unbounded timeouts.
  # Override per-call: opts[:think] = true/false
  # Override globally: OLLAMA_THINK=true in .env (sets :ollama_think in app env)
  defp maybe_add_think(body, model, opts) do
    case Keyword.get(opts, :think) do
      nil ->
        think_cfg = Application.get_env(:optimal_system_agent, :ollama_think)

        cond do
          think_cfg != nil ->
            Map.put(body, "think", think_cfg)

          thinking_model?(model) ->
            # Disable extended reasoning by default — prevents 10+ minute stalls
            Map.put(body, "think", false)

          true ->
            body
        end

      val ->
        Map.put(body, "think", val)
    end
  end

  # Returns true for models known to enter unbounded thinking phases by default.
  defp thinking_model?(model_name) do
    name = String.downcase(model_name)
    String.contains?(name, "thinking") or String.starts_with?(name, "kimi")
  end

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "type" => "function",
        "function" => %{
          "name" => tool.name,
          "description" => tool.description,
          "parameters" => tool.parameters
        }
      }
    end)
  end

  defp parse_tool_calls(%{"tool_calls" => calls}, _model) when is_list(calls) do
    Enum.map(calls, fn call ->
      %{
        id: call["id"] || generate_id(),
        name: call["function"]["name"],
        arguments: call["function"]["arguments"] || %{}
      }
    end)
  end

  defp parse_tool_calls(%{"content" => content}, model) when is_binary(content) do
    ToolCallParsers.parse(content, model)
  end

  defp parse_tool_calls(_, _model), do: []

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()

  defp collect_stream(resp, callback, acc) do
    ref = resp.body

    receive do
      {^ref, {:data, data}} ->
        {lines, new_buffer} = split_ndjson(acc.buffer <> data)
        acc = %{acc | buffer: new_buffer}

        acc =
          Enum.reduce(lines, acc, fn line, inner_acc ->
            process_ndjson_line(line, callback, inner_acc)
          end)

        collect_stream(resp, callback, acc)

      {^ref, :done} ->
        content = Text.strip_thinking_tokens(acc.content)

        tool_calls =
          if acc.tool_calls != [] do
            acc.tool_calls
          else
            ToolCallParsers.parse(acc.content, "ollama")
          end

        callback.({:done, %{content: content, tool_calls: tool_calls, usage: %{}}})
        :ok

      {^ref, {:error, reason}} ->
        Logger.error("Ollama stream error: #{inspect(reason)}")
        {:error, "Ollama stream error: #{inspect(reason)}"}

      {{Finch.HTTP1.Pool, _}, _} ->
        # Finch internal connection pool message — safely discard
        collect_stream(resp, callback, acc)

      other ->
        Logger.debug("[Ollama] collect_stream unexpected msg (ref=#{inspect(ref, limit: 2)}): #{inspect(other, limit: 4)}")
        collect_stream(resp, callback, acc)
    after
      620_000 ->
        Logger.error("Ollama stream timeout after 620s")
        {:error, "Ollama stream timeout"}
    end
  end

  # Split buffered data into complete NDJSON lines + partial remainder
  defp split_ndjson(data) do
    lines = String.split(data, "\n")
    {complete, [remainder]} = Enum.split(lines, -1)
    {Enum.reject(complete, &(&1 == "")), remainder}
  end

  defp process_ndjson_line(line, callback, acc) do
    case Jason.decode(line) do
      {:ok, %{"message" => %{"content" => text}}} when is_binary(text) and text != "" ->
        callback.({:text_delta, text})
        %{acc | content: acc.content <> text}

      # kimi-k2.5 and other thinking models send a "thinking" field during
      # extended reasoning before producing content or tool calls.
      {:ok, %{"message" => %{"thinking" => text}}} when is_binary(text) and text != "" ->
        callback.({:thinking_delta, text})
        acc

      {:ok, %{"message" => %{"tool_calls" => calls}}} when is_list(calls) ->
        tool_calls =
          Enum.map(calls, fn call ->
            %{
              id: call["id"] || generate_id(),
              name: call["function"]["name"],
              arguments: call["function"]["arguments"] || %{}
            }
          end)

        %{acc | tool_calls: acc.tool_calls ++ tool_calls}

      _ ->
        acc
    end
  end

  # Returns `[headers: [{"authorization", "Bearer <key>"}]]` when
  # OLLAMA_API_KEY is set (Ollama Cloud), empty list otherwise.
  defp auth_headers do
    case Application.get_env(:optimal_system_agent, :ollama_api_key) do
      key when is_binary(key) and key != "" ->
        [headers: [{"authorization", "Bearer #{key}"}]]

      _ ->
        []
    end
  end
end
