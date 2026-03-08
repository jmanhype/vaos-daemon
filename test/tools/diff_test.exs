defmodule OptimalSystemAgent.Tools.Builtins.DiffTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Diff

  # ---------------------------------------------------------------------------
  # Tool metadata
  # ---------------------------------------------------------------------------

  describe "tool metadata" do
    test "name returns diff" do
      assert Diff.name() == "diff"
    end

    test "description is a non-empty string" do
      desc = Diff.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end

    test "parameters returns valid JSON schema" do
      params = Diff.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "file_a")
      assert Map.has_key?(params["properties"], "file_b")
      assert Map.has_key?(params["properties"], "text_a")
      assert Map.has_key?(params["properties"], "text_b")
    end

    test "safety is :read_only" do
      assert Diff.safety() == :read_only
    end
  end

  # ---------------------------------------------------------------------------
  # File diff
  # ---------------------------------------------------------------------------

  describe "file diff" do
    test "identical files return 'Files are identical'" do
      path = "/tmp/osa_diff_test_#{:rand.uniform(100_000)}"
      file_a = "#{path}_a.txt"
      file_b = "#{path}_b.txt"

      try do
        File.write!(file_a, "hello\nworld\n")
        File.write!(file_b, "hello\nworld\n")
        assert {:ok, "Files are identical"} = Diff.execute(%{"file_a" => file_a, "file_b" => file_b})
      after
        File.rm(file_a)
        File.rm(file_b)
      end
    end

    test "different files return unified diff output" do
      path = "/tmp/osa_diff_test_#{:rand.uniform(100_000)}"
      file_a = "#{path}_a.txt"
      file_b = "#{path}_b.txt"

      try do
        File.write!(file_a, "line one\nline two\n")
        File.write!(file_b, "line one\nline three\n")
        assert {:ok, output} = Diff.execute(%{"file_a" => file_a, "file_b" => file_b})
        assert output =~ "line two"
        assert output =~ "line three"
      after
        File.rm(file_a)
        File.rm(file_b)
      end
    end

    test "nonexistent file_a returns error" do
      assert {:error, msg} = Diff.execute(%{"file_a" => "/tmp/nonexistent_a_999", "file_b" => "/tmp/nonexistent_b_999"})
      assert msg =~ "File not found"
    end

    test "nonexistent file_b returns error" do
      file_a = "/tmp/osa_diff_exists_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(file_a, "content")
        assert {:error, msg} = Diff.execute(%{"file_a" => file_a, "file_b" => "/tmp/nonexistent_999"})
        assert msg =~ "File not found"
      after
        File.rm(file_a)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Text diff
  # ---------------------------------------------------------------------------

  describe "text diff" do
    test "identical texts return 'Texts are identical'" do
      assert {:ok, "Texts are identical"} = Diff.execute(%{"text_a" => "same\n", "text_b" => "same\n"})
    end

    test "different texts return unified diff output" do
      assert {:ok, output} = Diff.execute(%{"text_a" => "alpha\n", "text_b" => "beta\n"})
      assert output =~ "alpha"
      assert output =~ "beta"
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  describe "parameter validation" do
    test "missing both pairs returns error" do
      assert {:error, msg} = Diff.execute(%{})
      assert msg =~ "Provide either"
    end

    test "only file_a without file_b returns error" do
      assert {:error, msg} = Diff.execute(%{"file_a" => "/tmp/foo"})
      assert msg =~ "Provide either"
    end

    test "only text_a without text_b returns error" do
      assert {:error, msg} = Diff.execute(%{"text_a" => "hello"})
      assert msg =~ "Provide either"
    end
  end
end
