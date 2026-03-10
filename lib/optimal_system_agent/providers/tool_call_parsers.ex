defmodule OptimalSystemAgent.Providers.ToolCallParsers do
  @moduledoc """
  Pure-function parsers for tool calls embedded in raw text output from local LLMs.

  Models served through Ollama often don't populate the structured `tool_calls`
  response field. Instead they emit tool invocations inline using model-specific
  markup (XML tags, unicode delimiters, special tokens, etc.).

  This module implements seven model-family parsers and an auto-detect chain:

    * Hermes / Qwen 2.5  — `<tool_call>{JSON}</tool_call>`
    * DeepSeek V3        — `<｜tool▁call▁begin｜>…<｜tool▁call▁end｜>`
    * Mistral / Mixtral   — `[TOOL_CALLS] [{JSON array}]`
    * Llama 3.x / 4      — `<|python_tag|>{JSON}`
    * GLM-4              — `<tool_call>name\\n{JSON}`
    * Kimi K2            — `<|tool_calls_section_begin|>…<|tool_calls_section_end|>`
    * Qwen3-Coder        — `<function=name><parameter=k>v</parameter></function>`

  The public entry point `parse/2` selects a parser by model-name prefix; when the
  model is unknown it falls back to trying every parser until one succeeds.
  """

  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map()}

  # Model prefix → parser function (order matters for prefix matching)
  @model_parsers [
    {"qwen3-coder", :parse_qwen3_coder},
    {"qwen2.5", :parse_hermes},
    {"hermes", :parse_hermes},
    {"deepseek", :parse_deepseek},
    {"mistral", :parse_mistral},
    {"mixtral", :parse_mistral},
    {"llama", :parse_llama},
    {"glm", :parse_glm},
    {"kimi", :parse_kimi}
  ]

  # Auto-detect order: most distinctive markers first
  @auto_detect_order [
    :parse_hermes,
    :parse_deepseek,
    :parse_mistral,
    :parse_llama,
    :parse_glm,
    :parse_kimi,
    :parse_qwen3_coder
  ]

  @doc """
  Parse tool calls from raw LLM text output using model-specific format detection.

  When `model` matches a known prefix the corresponding parser runs directly.
  Otherwise every parser is tried in order and the first non-empty result wins.

  Returns a list of `%{id, name, arguments}` maps, or `[]` when nothing is found.
  """
  @spec parse(String.t(), String.t() | nil) :: [tool_call()]
  def parse(content, model \\ nil)

  def parse(content, _model) when not is_binary(content) or content == "", do: []

  def parse(content, model) when is_binary(model) do
    downcased = String.downcase(model)

    case find_parser(downcased) do
      nil -> auto_detect(content)
      parser -> apply_parser(parser, content)
    end
  end

  def parse(content, _model), do: auto_detect(content)

  # ── Router ──────────────────────────────────────────────────────────

  defp find_parser(downcased_model) do
    Enum.find_value(@model_parsers, fn {prefix, parser} ->
      if String.starts_with?(downcased_model, prefix), do: parser
    end)
  end

  defp auto_detect(content) do
    Enum.find_value(@auto_detect_order, [], fn parser ->
      case apply_parser(parser, content) do
        [] -> nil
        calls -> calls
      end
    end)
  end

  defp apply_parser(parser, content) do
    apply(__MODULE__, :do_parse, [parser, content])
  end

  # ── Dispatch (public for apply/3, but undocumented) ─────────────────

  @doc false
  def do_parse(:parse_hermes, content), do: parse_hermes(content)
  def do_parse(:parse_deepseek, content), do: parse_deepseek(content)
  def do_parse(:parse_mistral, content), do: parse_mistral(content)
  def do_parse(:parse_llama, content), do: parse_llama(content)
  def do_parse(:parse_glm, content), do: parse_glm(content)
  def do_parse(:parse_kimi, content), do: parse_kimi(content)
  def do_parse(:parse_qwen3_coder, content), do: parse_qwen3_coder(content)

  # ── Hermes / Qwen 2.5 ──────────────────────────────────────────────
  # Format: <tool_call>{"name": "...", "arguments": {...}}</tool_call>

  @hermes_pattern ~r/<tool_call>\s*(\{.*?\})\s*<\/tool_call>/s

  defp parse_hermes(content) do
    @hermes_pattern
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_full, json_str] ->
      case Jason.decode(json_str) do
        {:ok, %{"name" => name, "arguments" => args}} when is_map(args) ->
          [%{id: generate_id(), name: name, arguments: args}]

        {:ok, %{"name" => name, "arguments" => args}} when is_binary(args) ->
          [%{id: generate_id(), name: name, arguments: safe_decode(args)}]

        {:ok, %{"name" => name}} ->
          [%{id: generate_id(), name: name, arguments: %{}}]

        _ ->
          []
      end
    end)
  end

  # ── DeepSeek V3 ────────────────────────────────────────────────────
  # Format: <｜tool▁call▁begin｜>function: name\n```json\n{...}\n```<｜tool▁call▁end｜>
  # The unicode chars are fullwidth bar (｜ U+FF5C) and lower block (▁ U+2581)

  @deepseek_begin "<\u{FF5C}tool\u{2581}call\u{2581}begin\u{FF5C}>"
  @deepseek_end "<\u{FF5C}tool\u{2581}call\u{2581}end\u{FF5C}>"

  defp parse_deepseek(content) do
    unless String.contains?(content, @deepseek_begin) do
      []
    else
      content
      |> String.split(@deepseek_begin)
      |> Enum.drop(1)
      |> Enum.flat_map(fn segment ->
        # Take only the part before the end delimiter
        segment = segment |> String.split(@deepseek_end) |> List.first() |> String.trim()

        # DeepSeek format: "function: name\n```json\n{...}\n```"
        # or simply: "name\n{...}"
        case parse_deepseek_segment(segment) do
          {:ok, name, args} -> [%{id: generate_id(), name: name, arguments: args}]
          :error -> []
        end
      end)
    end
  end

  defp parse_deepseek_segment(segment) do
    # Try "function: name\n..." first
    case Regex.run(~r/^(?:function:\s*)?(\S+)\s*\n(.*)/s, segment) do
      [_, name, rest] ->
        # Strip optional ```json ... ``` wrapper
        json_str =
          rest
          |> String.replace(~r/^```(?:json)?\s*/s, "")
          |> String.replace(~r/\s*```\s*$/s, "")
          |> String.trim()

        case Jason.decode(json_str) do
          {:ok, args} when is_map(args) -> {:ok, name, args}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # ── Mistral / Mixtral ──────────────────────────────────────────────
  # Format: [TOOL_CALLS] [{"name": "...", "arguments": {...}}]

  defp parse_mistral(content) do
    case Regex.run(~r/\[TOOL_CALLS\]\s*(\[.*\])/s, content) do
      [_, array_str] ->
        case Jason.decode(array_str) do
          {:ok, calls} when is_list(calls) ->
            Enum.flat_map(calls, fn
              %{"name" => name, "arguments" => args} when is_map(args) ->
                [%{id: generate_id(), name: name, arguments: args}]

              %{"name" => name, "arguments" => args} when is_binary(args) ->
                [%{id: generate_id(), name: name, arguments: safe_decode(args)}]

              %{"name" => name} ->
                [%{id: generate_id(), name: name, arguments: %{}}]

              _ ->
                []
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # ── Llama 3.x / 4 ─────────────────────────────────────────────────
  # Format: <|python_tag|>{"name": "...", "parameters": {...}}

  defp parse_llama(content) do
    case Regex.run(~r/<\|python_tag\|>\s*(\{.*\})/s, content) do
      [_, json_str] ->
        case Jason.decode(json_str) do
          {:ok, %{"name" => name, "parameters" => params}} when is_map(params) ->
            [%{id: generate_id(), name: name, arguments: params}]

          {:ok, %{"name" => name, "arguments" => args}} when is_map(args) ->
            [%{id: generate_id(), name: name, arguments: args}]

          {:ok, %{"name" => name}} ->
            [%{id: generate_id(), name: name, arguments: %{}}]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # ── GLM-4 ──────────────────────────────────────────────────────────
  # Format: <tool_call>function_name\n{"key": "value", ...}
  # Distinguished from Hermes by the lack of JSON wrapping the name.

  defp parse_glm(content) do
    # GLM uses <tool_call> but without the JSON wrapper around the name.
    # Pattern: <tool_call>\nname\n{json}\n or <tool_call>name\n{json}
    ~r/<tool_call>\s*(\w+)\s*\n\s*(\{[^}]*(?:\{[^}]*\}[^}]*)*\})/s
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_full, name, json_str] ->
      case Jason.decode(json_str) do
        {:ok, args} when is_map(args) ->
          [%{id: generate_id(), name: name, arguments: args}]

        _ ->
          []
      end
    end)
  end

  # ── Kimi K2 ────────────────────────────────────────────────────────
  # Format: <|tool_calls_section_begin|>function_name\n{JSON}<|tool_calls_section_end|>

  @kimi_begin "<|tool_calls_section_begin|>"
  @kimi_end "<|tool_calls_section_end|>"

  defp parse_kimi(content) do
    unless String.contains?(content, @kimi_begin) do
      []
    else
      content
      |> String.split(@kimi_begin)
      |> Enum.drop(1)
      |> Enum.flat_map(fn segment ->
        segment = segment |> String.split(@kimi_end) |> List.first() |> String.trim()

        case Regex.run(~r/^(\w+)\s*\n\s*(\{.*\})/s, segment) do
          [_, name, json_str] ->
            case Jason.decode(json_str) do
              {:ok, args} when is_map(args) ->
                [%{id: generate_id(), name: name, arguments: args}]

              _ ->
                []
            end

          _ ->
            []
        end
      end)
    end
  end

  # ── Qwen3-Coder ───────────────────────────────────────────────────
  # Format: <function=name><parameter=key>value</parameter>...</function>

  @qwen3_fn_pattern ~r/<function=(\w+)>(.*?)<\/function>/s
  @qwen3_param_pattern ~r/<parameter=(\w+)>(.*?)<\/parameter>/s

  defp parse_qwen3_coder(content) do
    @qwen3_fn_pattern
    |> Regex.scan(content)
    |> Enum.map(fn [_full, name, body] ->
      args =
        @qwen3_param_pattern
        |> Regex.scan(body)
        |> Enum.reduce(%{}, fn [_full, key, value], acc ->
          # Try to parse value as JSON for structured types, fall back to string
          parsed =
            case Jason.decode(value) do
              {:ok, v} -> v
              _ -> value
            end

          Map.put(acc, key, parsed)
        end)

      %{id: generate_id(), name: name, arguments: args}
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp safe_decode(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate("tc")
end
