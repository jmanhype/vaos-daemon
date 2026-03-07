defmodule OptimalSystemAgent.Tools.Builtins.FileReadTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.FileRead

  # ---------------------------------------------------------------------------
  # Blocked sensitive paths
  # ---------------------------------------------------------------------------

  describe "blocked sensitive paths" do
    test "reading /etc/shadow is blocked" do
      assert {:error, msg} = FileRead.execute(%{"path" => "/etc/shadow"})
      assert msg =~ "Access denied"
    end

    test "reading /etc/passwd is blocked" do
      assert {:error, msg} = FileRead.execute(%{"path" => "/etc/passwd"})
      assert msg =~ "Access denied"
    end

    test "reading ~/.ssh/id_rsa is blocked" do
      assert {:error, msg} = FileRead.execute(%{"path" => "~/.ssh/id_rsa"})
      assert msg =~ "Access denied"
    end

    test "reading ~/.ssh/id_ed25519 is blocked" do
      assert {:error, msg} = FileRead.execute(%{"path" => "~/.ssh/id_ed25519"})
      assert msg =~ "Access denied"
    end

    test "reading ~/.ssh/id_ecdsa is blocked" do
      assert {:error, msg} = FileRead.execute(%{"path" => "~/.ssh/id_ecdsa"})
      assert msg =~ "Access denied"
    end
  end

  # ---------------------------------------------------------------------------
  # Allowed paths
  # ---------------------------------------------------------------------------

  describe "allowed paths" do
    test "reading a normal file works" do
      path = "/tmp/osa_test_read_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "test content")
        assert {:ok, "test content"} = FileRead.execute(%{"path" => path})
      after
        File.rm(path)
      end
    end

    test "reading a nonexistent file returns error" do
      assert {:error, msg} = FileRead.execute(%{"path" => "/tmp/definitely_does_not_exist_12345"})
      assert msg =~ "Error reading file"
    end

    test "reading ~/.ssh/config is allowed (not a private key)" do
      # We just test it doesn't get the "Access denied" error.
      # It may fail with file-not-found which is fine.
      result = FileRead.execute(%{"path" => "~/.ssh/config"})

      case result do
        {:ok, _} -> assert true
        {:error, msg} -> refute msg =~ "Access denied"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Offset and limit
  # ---------------------------------------------------------------------------

  describe "offset and limit" do
    test "offset reads from the given line number" do
      path = "/tmp/osa_test_offset_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "line1\nline2\nline3\nline4\nline5\n")
        assert {:ok, output} = FileRead.execute(%{"path" => path, "offset" => 3})
        # Should start at line 3
        assert output =~ "3| line3"
        assert output =~ "4| line4"
        assert output =~ "5| line5"
        refute output =~ "1| line1"
        refute output =~ "2| line2"
      after
        File.rm(path)
      end
    end

    test "limit restricts number of lines returned" do
      path = "/tmp/osa_test_limit_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "line1\nline2\nline3\nline4\nline5\n")
        assert {:ok, output} = FileRead.execute(%{"path" => path, "limit" => 2})
        assert output =~ "1| line1"
        assert output =~ "2| line2"
        refute output =~ "3| line3"
      after
        File.rm(path)
      end
    end

    test "offset and limit together read a specific range" do
      path = "/tmp/osa_test_range_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "a\nb\nc\nd\ne\nf\n")
        assert {:ok, output} = FileRead.execute(%{"path" => path, "offset" => 2, "limit" => 3})
        # Should contain lines 2, 3, 4
        assert output =~ "2| b"
        assert output =~ "3| c"
        assert output =~ "4| d"
        refute output =~ "1| a"
        refute output =~ "5| e"
      after
        File.rm(path)
      end
    end

    test "offset beyond file length returns error" do
      path = "/tmp/osa_test_beyond_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "only\ntwo\n")
        assert {:error, msg} = FileRead.execute(%{"path" => path, "offset" => 100})
        assert msg =~ "No lines in range"
      after
        File.rm(path)
      end
    end

    test "line numbers are right-aligned with padding" do
      path = "/tmp/osa_test_padding_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "content\n")
        assert {:ok, output} = FileRead.execute(%{"path" => path, "offset" => 1, "limit" => 1})
        # Line number should be padded to 5 chars
        assert output =~ "    1| content"
      after
        File.rm(path)
      end
    end

    test "without offset or limit reads full file content" do
      path = "/tmp/osa_test_full_#{:rand.uniform(100_000)}.txt"

      try do
        File.write!(path, "full content here")
        assert {:ok, "full content here"} = FileRead.execute(%{"path" => path})
      after
        File.rm(path)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Metadata
  # ---------------------------------------------------------------------------

  describe "tool metadata" do
    test "name returns file_read" do
      assert FileRead.name() == "file_read"
    end

    test "parameters returns valid JSON schema" do
      params = FileRead.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "path")
      assert Map.has_key?(params["properties"], "offset")
      assert Map.has_key?(params["properties"], "limit")
    end
  end
end
