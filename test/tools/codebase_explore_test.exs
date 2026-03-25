defmodule Daemon.Tools.Builtins.CodebaseExploreTest do
  use ExUnit.Case, async: true

  alias Daemon.Tools.Builtins.CodebaseExplore

  describe "name/0" do
    test "returns codebase_explore" do
      assert CodebaseExplore.name() == "codebase_explore"
    end
  end

  describe "description/0" do
    test "returns a description" do
      desc = CodebaseExplore.description()
      assert is_binary(desc)
      assert String.contains?(desc, "codebase")
    end
  end

  describe "parameters/0" do
    test "returns valid parameter schema" do
      params = CodebaseExplore.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "goal")
      assert Map.has_key?(params["properties"], "path")
      assert Map.has_key?(params["properties"], "depth")
      assert "goal" in params["required"]
    end

    test "depth has valid enum values" do
      params = CodebaseExplore.parameters()
      depth = params["properties"]["depth"]
      assert depth["enum"] == ["quick", "standard", "deep"]
    end
  end

  describe "execute/1" do
    test "returns error when goal is missing" do
      assert {:error, _} = CodebaseExplore.execute(%{})
    end

    test "executes quick exploration on current directory" do
      # This test runs against the actual OSA project directory
      result = CodebaseExplore.execute(%{
        "goal" => "understand project structure",
        "depth" => "quick"
      })

      assert {:ok, content} = result
      assert is_binary(content)
      assert String.contains?(content, "Codebase Exploration")
      assert String.contains?(content, "Project type:")
    end

    test "executes standard exploration with config reading" do
      result = CodebaseExplore.execute(%{
        "goal" => "authentication",
        "depth" => "standard"
      })

      assert {:ok, content} = result
      assert is_binary(content)
      assert String.contains?(content, "Codebase Exploration")
    end

    test "handles non-existent path gracefully" do
      result = CodebaseExplore.execute(%{
        "goal" => "test",
        "path" => "/tmp/nonexistent_dir_#{:erlang.unique_integer([:positive])}",
        "depth" => "quick"
      })

      assert {:ok, content} = result
      assert is_binary(content)
    end

    test "defaults to standard depth" do
      result = CodebaseExplore.execute(%{"goal" => "project overview"})
      assert {:ok, content} = result
      assert is_binary(content)
    end

    test "respects output size cap" do
      result = CodebaseExplore.execute(%{
        "goal" => "everything",
        "depth" => "deep"
      })

      assert {:ok, content} = result
      # Deep exploration should still be capped
      assert byte_size(content) <= 13_000
    end
  end
end
