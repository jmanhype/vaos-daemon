defmodule OptimalSystemAgent.Providers.OpenAICompat do
  @moduledoc """
  Shared chat completion logic for all OpenAI-compatible APIs.

  Providers that use this module only need to supply:
  - base URL
  - API key
  - model name

  The wire format (POST /chat/completions), tool call formatting, and
  response parsing are identical across all OpenAI-compatible endpoints.
  """

  require Logger

  alias OptimalSystemAgent.Providers.ToolCallParsers
  alias OptimalSystemAgent.Utils.Text

  @doc """
  Execute a chat completion against any OpenAI-compatible endpoint.

  Returns `{:ok, %{content: String.t(), tool_calls: list()}}` or `{:error, reason}`.
  """
  @spec chat(String.t(), String.t() | nil, String.t(), list(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def chat(base_url, api_key, model, messages, opts) do
    unless api_key do
      {:error, "API key not configured"}
    else
      do_chat(base_url, api_key, model, messages, opts)
    end
  end

  defp do_chat(base_url, api_key, model, messages, opts) do
    body =
      %{
        model: model,
        messages: format_messages(messages),
        temperature: Keyword.get(opts, :temperature, 0.7)
      }
      |> maybe_add_tools(opts)
      |> maybe_add_max_tokens(opts)

    extra_headers = Keyword.get(opts, :extra_headers, [])

    headers =
      [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"}
      ] ++ extra_headers

    url = "#{base_url}/chat/completions"

    try do
      case Req.post(url, json: body, headers: headers, receive_timeout: 120_000) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => msg} | _]} = resp}} ->
          content = Text.strip_thinking_tokens(msg["content"] || "")
          tool_calls = parse_tool_calls(msg)
          usage = parse_usage(resp)
          {:ok, %{content: content, tool_calls: tool_calls, usage: usage}}

        {:ok, %{status: status, body: resp_body}} ->
          error_msg = extract_error_message(resp_body)
          {:error, "HTTP #{status}: #{error_msg}"}

        {:error, reason} ->
          {:error, "Connection failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, "Unexpected error: #{Exception.message(e)}"}
    end
  end

  @doc "Format messages into the OpenAI wire format."
  def format_messages(messages) do
    Enum.map(messages, fn
      # Tool result messages — preserve tool_call_id for the API
      %{role: "tool", content: content, tool_call_id: id} ->
        %{"role" => "tool", "content" => to_string(content), "tool_call_id" => to_string(id)}

      # Assistant messages with tool_calls — preserve structured tool calls
      %{role: "assistant", content: content, tool_calls: calls} when is_list(calls) and calls != [] ->
        msg = %{"role" => "assistant", "content" => to_string(content)}

        formatted_calls =
          Enum.map(calls, fn tc ->
            %{
              "id" => to_string(tc[:id] || tc["id"] || ""),
              "type" => "function",
              "function" => %{
                "name" => to_string(tc[:name] || tc["name"] || ""),
                "arguments" =>
                  case tc[:arguments] || tc["arguments"] do
                    a when is_binary(a) -> a
                    a when is_map(a) -> Jason.encode!(a)
                    _ -> "{}"
                  end
              }
            }
          end)

        Map.put(msg, "tool_calls", formatted_calls)

      # Generic atom-keyed messages
      %{role: role, content: content} ->
        %{"role" => to_string(role), "content" => to_string(content)}

      %{"role" => _role} = msg ->
        msg

      msg when is_map(msg) ->
        msg
    end)
  end

  @doc "Format tools into the OpenAI function-calling format."
  def format_tools(tools) do
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

  @doc "Parse tool_calls from an OpenAI-style message map."
  def parse_tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.map(calls, fn call ->
      args =
        case Jason.decode(call["function"]["arguments"] || "{}") do
          {:ok, parsed} -> parsed
          _ -> %{}
        end

      %{
        id: call["id"] || generate_id(),
        name: call["function"]["name"] |> to_string() |> String.split(~r/\s+/) |> List.first(),
        arguments: args
      }
    end)
  end

  # Fallback: detect tool calls embedded as XML/JSON in the content field
  def parse_tool_calls(%{"content" => content}) when is_binary(content) do
    parse_tool_calls_from_content(content)
  end

  def parse_tool_calls(_), do: []

  @doc """
  Model-aware variant — tries model-specific parsers before the generic fallback.
  """
  def parse_tool_calls(%{"tool_calls" => calls}, _model) when is_list(calls) do
    parse_tool_calls(%{"tool_calls" => calls})
  end

  def parse_tool_calls(%{"content" => content} = _msg, model) when is_binary(content) do
    case ToolCallParsers.parse(content, model) do
      [] -> parse_tool_calls_from_content(content)
      calls -> calls
    end
  end

  def parse_tool_calls(msg, _model), do: parse_tool_calls(msg)

  @doc false
  def parse_tool_calls_from_content(content) when is_binary(content) do
    cond do
      # Format 2: <function_call>{"name": "...", "arguments": {...}}</function_call>
      # Must be checked BEFORE Format 1 — "<function_call>" contains "<function"
      String.contains?(content, "<function_call>") ->
        ~r/<function_call>\s*/s
        |> Regex.split(content, include_captures: false)
        |> Enum.drop(1)
        |> Enum.flat_map(fn chunk ->
          case extract_balanced_json(chunk) do
            {:ok, json_str} ->
              case Jason.decode(json_str) do
                {:ok, %{"name" => name, "arguments" => args}} when is_map(args) ->
                  [%{id: generate_id(), name: normalize_tool_name(name), arguments: args}]

                {:ok, %{"name" => name, "arguments" => args}} when is_binary(args) ->
                  parsed = case Jason.decode(args) do
                    {:ok, a} -> a
                    _ -> %{}
                  end
                  [%{id: generate_id(), name: normalize_tool_name(name), arguments: parsed}]

                _ -> []
              end

            _ -> []
          end
        end)

      # Format 1: <function name="tool_name" parameters={...}></function>
      String.contains?(content, "<function") ->
        extract_xml_function_calls(content)

      # Format 3: raw JSON tool call object {"name": "...", "arguments": {...}}
      String.contains?(content, "\"name\"") and String.contains?(content, "\"arguments\"") ->
        extract_json_tool_calls(content)

      true ->
        []
    end
  end

  def parse_tool_calls_from_content(_), do: []

  # Extract <function name="..." parameters={...}></function> tags with proper
  # balanced-brace JSON parsing (fixes non-greedy regex failure on nested JSON).
  @xml_fn_pattern ~r/<function\s+name="([^"]+)"\s+parameters=/

  defp extract_xml_function_calls(content) do
    @xml_fn_pattern
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(fn [{match_start, match_len}, {name_start, name_len}] ->
      name = binary_part(content, name_start, name_len)
      json_offset = match_start + match_len
      rest = binary_part(content, json_offset, byte_size(content) - json_offset)

      case extract_balanced_json(rest) do
        {:ok, args_str} ->
          args = case Jason.decode(args_str) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end
          [%{id: generate_id(), name: normalize_tool_name(name), arguments: args}]

        _ -> []
      end
    end)
  end

  # Extract all JSON tool call objects from free-form text (Format 3).
  defp extract_json_tool_calls(content) do
    content
    |> scan_json_objects()
    |> Enum.flat_map(fn json_str ->
      case Jason.decode(json_str) do
        {:ok, %{"name" => name, "arguments" => args}} when is_map(args) ->
          [%{id: generate_id(), name: normalize_tool_name(name), arguments: args}]
        _ -> []
      end
    end)
  end

  # Scan a string for all top-level JSON objects, returning them as strings.
  defp scan_json_objects(str), do: scan_json_objects(str, [])

  defp scan_json_objects("", acc), do: Enum.reverse(acc)

  defp scan_json_objects(str, acc) do
    case :binary.match(str, "{") do
      :nomatch ->
        Enum.reverse(acc)

      {pos, 1} ->
        substr = binary_part(str, pos, byte_size(str) - pos)

        case extract_balanced_json(substr) do
          {:ok, json_str} ->
            rest_pos = pos + byte_size(json_str)
            rest = binary_part(str, rest_pos, byte_size(str) - rest_pos)
            scan_json_objects(rest, [json_str | acc])

          _ ->
            rest = binary_part(str, pos + 1, byte_size(str) - pos - 1)
            scan_json_objects(rest, acc)
        end
    end
  end

  # Extract a balanced JSON object starting at the first `{` in the string.
  # Handles nested objects and quoted strings (including escaped quotes).
  # Returns {:ok, json_string} or :error.
  defp extract_balanced_json(str) do
    case :binary.match(str, "{") do
      :nomatch -> :error
      {start, 1} ->
        substr = binary_part(str, start, byte_size(str) - start)
        case scan_balanced(substr, 0, 0) do
          {:ok, len} -> {:ok, binary_part(substr, 0, len)}
          :error -> :error
        end
    end
  end

  defp scan_balanced(str, depth, pos)

  defp scan_balanced("", depth, _pos) when depth > 0, do: :error
  defp scan_balanced("", 0, pos), do: {:ok, pos}

  # Enter a quoted string — skip until closing unescaped quote
  defp scan_balanced(<<"\"", rest::binary>>, depth, pos) do
    case skip_json_string(rest, pos + 1) do
      {:ok, new_pos} -> scan_balanced(binary_part(rest, new_pos - pos - 1, byte_size(rest) - (new_pos - pos - 1)), depth, new_pos)
      :error -> :error
    end
  end

  defp scan_balanced(<<"{", rest::binary>>, depth, pos) do
    scan_balanced(rest, depth + 1, pos + 1)
  end

  defp scan_balanced(<<"}", _rest::binary>>, 1, pos) do
    {:ok, pos + 1}
  end

  defp scan_balanced(<<"}", rest::binary>>, depth, pos) when depth > 1 do
    scan_balanced(rest, depth - 1, pos + 1)
  end

  defp scan_balanced(<<_byte, rest::binary>>, depth, pos) do
    scan_balanced(rest, depth, pos + 1)
  end

  # Skip over a JSON string (already consumed the opening `"`).
  # Returns {:ok, position_after_closing_quote} or :error.
  defp skip_json_string(str, pos)

  defp skip_json_string("", _pos), do: :error

  defp skip_json_string(<<"\\", _escaped, rest::binary>>, pos) do
    skip_json_string(rest, pos + 2)
  end

  defp skip_json_string(<<"\"", _rest::binary>>, pos) do
    {:ok, pos + 1}
  end

  defp skip_json_string(<<_byte, rest::binary>>, pos) do
    skip_json_string(rest, pos + 1)
  end

  defp normalize_tool_name(name) when is_binary(name) do
    name |> String.split(~r/[\s({]/) |> List.first() |> String.trim()
  end

  # --- Private helpers ---

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools -> Map.put(body, :tools, format_tools(tools))
    end
  end

  defp maybe_add_max_tokens(body, opts) do
    case Keyword.get(opts, :max_tokens) do
      nil -> body
      n -> Map.put(body, :max_tokens, n)
    end
  end

  defp parse_usage(%{"usage" => %{"prompt_tokens" => inp, "completion_tokens" => out}}),
    do: %{input_tokens: inp, output_tokens: out}

  defp parse_usage(_), do: %{}

  defp extract_error_message(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error_message(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error_message(body), do: inspect(body)

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()
end
