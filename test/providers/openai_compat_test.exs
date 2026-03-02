defmodule OptimalSystemAgent.Providers.OpenAICompatTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.OpenAICompat

  describe "parse_tool_calls_from_content/1" do
    test "returns empty list for plain text" do
      assert OpenAICompat.parse_tool_calls_from_content("Hello world") == []
    end

    test "returns empty list for nil / non-binary" do
      assert OpenAICompat.parse_tool_calls_from_content(nil) == []
      assert OpenAICompat.parse_tool_calls_from_content(42) == []
    end

    # -- Format 1: <function name="..." parameters={...}></function> --

    test "parses simple XML function tag" do
      content = ~s|<function name="file_read" parameters={"path": "/foo/bar"}></function>|
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "file_read"
      assert tc.arguments == %{"path" => "/foo/bar"}
      assert is_binary(tc.id)
    end

    test "parses XML function tag with nested JSON arguments (Bug 4 fix)" do
      content = ~s|<function name="shell_execute" parameters={"command": "ls", "options": {"cwd": "/tmp", "timeout": 30}}></function>|
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "shell_execute"
      assert tc.arguments["command"] == "ls"
      assert tc.arguments["options"] == %{"cwd" => "/tmp", "timeout" => 30}
    end

    test "parses multiple XML function tags" do
      content =
        ~s|<function name="file_read" parameters={"path": "/a"}></function>| <>
          "\n" <>
          ~s|<function name="file_write" parameters={"path": "/b", "content": "hi"}></function>|

      tcs = OpenAICompat.parse_tool_calls_from_content(content)
      assert length(tcs) == 2
      names = Enum.map(tcs, & &1.name)
      assert "file_read" in names
      assert "file_write" in names
    end

    test "handles XML with string values containing braces" do
      content = ~s|<function name="eval" parameters={"code": "if (x > 0) { return x; }"}></function>|
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "eval"
      assert tc.arguments["code"] == "if (x > 0) { return x; }"
    end

    test "returns empty args map for malformed XML JSON" do
      content = ~s|<function name="bad_tool" parameters={not valid json}></function>|
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "bad_tool"
      assert tc.arguments == %{}
    end

    # -- Format 2: <function_call>{...}</function_call> --

    test "parses function_call tag format" do
      content = ~s|<function_call>{"name": "web_search", "arguments": {"query": "elixir otp"}}</function_call>|
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "web_search"
      assert tc.arguments == %{"query" => "elixir otp"}
    end

    test "parses function_call with nested arguments" do
      content = ~s|<function_call>{"name": "orchestrate", "arguments": {"task": "research", "opts": {"depth": 3, "parallel": true}}}</function_call>|
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "orchestrate"
      assert tc.arguments["opts"] == %{"depth" => 3, "parallel" => true}
    end

    test "parses multiple function_call tags" do
      content =
        ~s|<function_call>{"name": "tool_a", "arguments": {}}</function_call>| <>
          "\n" <>
          ~s|<function_call>{"name": "tool_b", "arguments": {"x": 1}}</function_call>|

      tcs = OpenAICompat.parse_tool_calls_from_content(content)
      assert length(tcs) == 2
      assert Enum.any?(tcs, &(&1.name == "tool_a"))
      assert Enum.any?(tcs, &(&1.name == "tool_b"))
    end

    # -- Format 3: raw JSON {"name": "...", "arguments": {...}} --

    test "parses raw JSON tool call" do
      content = ~s|{"name": "memory_save", "arguments": {"key": "foo", "value": "bar"}}|
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "memory_save"
      assert tc.arguments == %{"key" => "foo", "value" => "bar"}
    end

    test "parses raw JSON with nested arguments" do
      content = ~s|{"name": "file_edit", "arguments": {"path": "/x", "changes": {"line": 5, "text": "hello"}}}|
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "file_edit"
      assert tc.arguments["changes"] == %{"line" => 5, "text" => "hello"}
    end
  end

  describe "parse_tool_calls/1" do
    test "parses native OpenAI tool_calls format" do
      msg = %{
        "tool_calls" => [
          %{
            "id" => "call_123",
            "function" => %{
              "name" => "file_read",
              "arguments" => Jason.encode!(%{"path" => "/etc/hosts"})
            }
          }
        ]
      }
      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.id == "call_123"
      assert tc.name == "file_read"
      assert tc.arguments == %{"path" => "/etc/hosts"}
    end

    test "falls back to content parsing when no tool_calls key" do
      msg = %{"content" => ~s|<function name="ping" parameters={"host": "localhost"}></function>|}
      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.name == "ping"
    end

    test "returns empty list when nothing is found" do
      assert OpenAICompat.parse_tool_calls(%{"content" => "plain text"}) == []
      assert OpenAICompat.parse_tool_calls(%{}) == []
    end

    test "strips whitespace from tool name (Bug 5 fix)" do
      msg = %{
        "tool_calls" => [
          %{
            "id" => "call_xyz",
            "function" => %{
              "name" => "file_read  extra_garbage",
              "arguments" => "{}"
            }
          }
        ]
      }
      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.name == "file_read"
    end
  end

  describe "format_messages/1" do
    test "formats simple user message" do
      msgs = [%{role: "user", content: "hello"}]
      [formatted] = OpenAICompat.format_messages(msgs)
      assert formatted == %{"role" => "user", "content" => "hello"}
    end

    test "formats tool result message with tool_call_id" do
      msgs = [%{role: "tool", content: "result", tool_call_id: "call_1"}]
      [formatted] = OpenAICompat.format_messages(msgs)
      assert formatted["role"] == "tool"
      assert formatted["tool_call_id"] == "call_1"
    end

    test "formats assistant message with tool_calls" do
      msgs = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{id: "call_1", name: "foo", arguments: %{"x" => 1}}]
        }
      ]
      [formatted] = OpenAICompat.format_messages(msgs)
      assert formatted["role"] == "assistant"
      assert [tc] = formatted["tool_calls"]
      assert tc["function"]["name"] == "foo"
    end
  end
end
