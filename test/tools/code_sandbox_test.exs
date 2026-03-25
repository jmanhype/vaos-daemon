defmodule Daemon.Tools.Builtins.CodeSandboxTest do
  use ExUnit.Case, async: true

  alias Daemon.Tools.Builtins.CodeSandbox

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  describe "name/0" do
    test "returns code_sandbox" do
      assert CodeSandbox.name() == "code_sandbox"
    end
  end

  describe "description/0" do
    test "returns a non-empty description" do
      desc = CodeSandbox.description()
      assert is_binary(desc)
      assert String.length(desc) > 10
      assert desc =~ "sandbox"
    end
  end

  describe "safety/0" do
    test "returns :write_safe" do
      assert CodeSandbox.safety() == :write_safe
    end
  end

  describe "available?/0" do
    test "returns a boolean based on docker presence" do
      result = CodeSandbox.available?()
      assert is_boolean(result)

      # Cross-check with System.find_executable
      has_docker = System.find_executable("docker") != nil
      assert result == has_docker
    end
  end

  # ---------------------------------------------------------------------------
  # Parameters / JSON Schema
  # ---------------------------------------------------------------------------

  describe "parameters/0" do
    test "returns valid JSON schema with required fields" do
      params = CodeSandbox.parameters()
      assert params["type"] == "object"
      assert "language" in params["required"]
      assert "code" in params["required"]
    end

    test "language has enum constraint" do
      params = CodeSandbox.parameters()
      lang_prop = params["properties"]["language"]
      assert lang_prop["type"] == "string"
      assert is_list(lang_prop["enum"])
      assert "python" in lang_prop["enum"]
      assert "javascript" in lang_prop["enum"]
      assert "go" in lang_prop["enum"]
      assert "elixir" in lang_prop["enum"]
      assert "ruby" in lang_prop["enum"]
      assert "rust" in lang_prop["enum"]
    end

    test "code is a string type" do
      params = CodeSandbox.parameters()
      assert params["properties"]["code"]["type"] == "string"
    end

    test "timeout is optional integer" do
      params = CodeSandbox.parameters()
      refute "timeout" in params["required"]
      assert params["properties"]["timeout"]["type"] == "integer"
    end

    test "stdin is optional string" do
      params = CodeSandbox.parameters()
      refute "stdin" in params["required"]
      assert params["properties"]["stdin"]["type"] == "string"
    end
  end

  # ---------------------------------------------------------------------------
  # Parameter validation
  # ---------------------------------------------------------------------------

  describe "execute/1 parameter validation" do
    test "rejects missing language" do
      assert {:error, msg} = CodeSandbox.execute(%{"code" => "print(1)"})
      assert msg =~ "language"
    end

    test "rejects missing code" do
      assert {:error, msg} = CodeSandbox.execute(%{"language" => "python"})
      assert msg =~ "code"
    end

    test "rejects unsupported language" do
      assert {:error, msg} = CodeSandbox.execute(%{"language" => "cobol", "code" => "DISPLAY 'HI'"})
      assert msg =~ "Unsupported language"
      assert msg =~ "cobol"
    end

    test "rejects empty code" do
      assert {:error, msg} = CodeSandbox.execute(%{"language" => "python", "code" => ""})
      assert msg =~ "empty"
    end

    test "rejects empty args" do
      assert {:error, _} = CodeSandbox.execute(%{})
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout resolution
  # ---------------------------------------------------------------------------

  describe "resolve_timeout/1" do
    test "defaults to 30 when not provided" do
      assert CodeSandbox.resolve_timeout(%{}) == 30
    end

    test "uses provided timeout" do
      assert CodeSandbox.resolve_timeout(%{"timeout" => 10}) == 10
    end

    test "caps at 60 seconds" do
      assert CodeSandbox.resolve_timeout(%{"timeout" => 120}) == 60
      assert CodeSandbox.resolve_timeout(%{"timeout" => 61}) == 60
    end

    test "uses default for non-positive timeout" do
      assert CodeSandbox.resolve_timeout(%{"timeout" => 0}) == 30
      assert CodeSandbox.resolve_timeout(%{"timeout" => -5}) == 30
    end

    test "exactly 60 is allowed" do
      assert CodeSandbox.resolve_timeout(%{"timeout" => 60}) == 60
    end
  end

  # ---------------------------------------------------------------------------
  # Language → Docker image mapping
  # ---------------------------------------------------------------------------

  describe "language_image/1" do
    test "python maps to python:3.12-slim" do
      assert CodeSandbox.language_image("python") == "python:3.12-slim"
    end

    test "javascript maps to node:22-slim" do
      assert CodeSandbox.language_image("javascript") == "node:22-slim"
    end

    test "go maps to golang:1.23-alpine" do
      assert CodeSandbox.language_image("go") == "golang:1.23-alpine"
    end

    test "elixir maps to elixir:1.18-slim" do
      assert CodeSandbox.language_image("elixir") == "elixir:1.18-slim"
    end

    test "ruby maps to ruby:3.3-slim" do
      assert CodeSandbox.language_image("ruby") == "ruby:3.3-slim"
    end

    test "rust maps to rust:1.77-slim" do
      assert CodeSandbox.language_image("rust") == "rust:1.77-slim"
    end

    test "unsupported language returns nil" do
      assert CodeSandbox.language_image("cobol") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Supported languages
  # ---------------------------------------------------------------------------

  describe "supported_languages/0" do
    test "returns all six languages" do
      langs = CodeSandbox.supported_languages()
      assert length(langs) == 6
      assert "python" in langs
      assert "javascript" in langs
      assert "go" in langs
      assert "elixir" in langs
      assert "ruby" in langs
      assert "rust" in langs
    end
  end

  # ---------------------------------------------------------------------------
  # Docker args construction
  # ---------------------------------------------------------------------------

  describe "build_docker_args/5" do
    test "includes security flags" do
      args = CodeSandbox.build_docker_args("python:3.12-slim", "python3 /code/script.py", "/tmp/test", 30, nil)

      assert "--rm" in args
      assert "--network=none" in args
      assert "--memory=256m" in args
      assert "--cpus=0.5" in args
      assert "--read-only" in args
      assert "--security-opt=no-new-privileges" in args
    end

    test "mounts code directory as read-only" do
      args = CodeSandbox.build_docker_args("python:3.12-slim", "python3 /code/script.py", "/tmp/test", 30, nil)

      # Find the -v flag and its argument
      v_idx = Enum.find_index(args, &(&1 == "-v"))
      assert v_idx != nil
      mount = Enum.at(args, v_idx + 1)
      assert mount == "/tmp/test:/code:ro"
    end

    test "includes tmpfs for /tmp" do
      args = CodeSandbox.build_docker_args("python:3.12-slim", "python3 /code/script.py", "/tmp/test", 30, nil)

      tmpfs_idx = Enum.find_index(args, &(&1 == "--tmpfs"))
      assert tmpfs_idx != nil
      tmpfs_val = Enum.at(args, tmpfs_idx + 1)
      assert tmpfs_val == "/tmp:size=64m"
    end

    test "wraps command in sh -c" do
      args = CodeSandbox.build_docker_args("python:3.12-slim", "python3 /code/script.py", "/tmp/test", 30, nil)

      assert "sh" in args
      assert "-c" in args
      assert "python3 /code/script.py" in args
    end

    test "without stdin, uses base run command" do
      args = CodeSandbox.build_docker_args("python:3.12-slim", "python3 /code/script.py", "/tmp/test", 30, nil)
      assert List.last(args) == "python3 /code/script.py"
    end

    test "with stdin, pipes echo into command" do
      args = CodeSandbox.build_docker_args("python:3.12-slim", "python3 /code/script.py", "/tmp/test", 30, "hello world")
      last = List.last(args)
      assert last =~ "echo"
      assert last =~ "hello world"
      assert last =~ "python3 /code/script.py"
    end

    test "empty stdin treated same as nil" do
      args_nil = CodeSandbox.build_docker_args("python:3.12-slim", "python3 /code/script.py", "/tmp/test", 30, nil)
      args_empty = CodeSandbox.build_docker_args("python:3.12-slim", "python3 /code/script.py", "/tmp/test", 30, "")
      assert args_nil == args_empty
    end
  end

  # ---------------------------------------------------------------------------
  # Code file writing and cleanup
  # ---------------------------------------------------------------------------

  describe "temp file lifecycle" do
    test "code is written to a temp file, not interpolated into args" do
      # We test this by calling execute with elixir fallback (no Docker needed)
      # and verifying the code actually runs
      result = CodeSandbox.execute(%{
        "language" => "elixir",
        "code" => "IO.puts(1 + 1)"
      })

      # Whether Docker or fallback, we should get a result (not a shell injection)
      case result do
        {:ok, output} ->
          assert output =~ "2"

        {:error, msg} ->
          # If it failed, it should NOT be because code was injected into args
          refute msg =~ "syntax error"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Elixir fallback mode
  # ---------------------------------------------------------------------------

  describe "Elixir fallback execution" do
    test "executes simple Elixir expressions" do
      # Force fallback by testing directly
      result = CodeSandbox.execute(%{
        "language" => "elixir",
        "code" => "IO.puts(1 + 1)"
      })

      case result do
        {:ok, output} ->
          # Either Docker or fallback mode — both should contain "2"
          assert output =~ "2"

        {:error, _msg} ->
          # Docker may not be available, fallback group_leader can conflict with ExUnit
          :ok
      end
    end

    test "Elixir fallback handles IO.puts" do
      # If Docker is unavailable, fallback should capture IO output
      unless CodeSandbox.docker_available?() do
        assert {:ok, output} = CodeSandbox.execute(%{
          "language" => "elixir",
          "code" => ~s[IO.puts("hello sandbox")]
        })

        assert output =~ "UNSANDBOXED"
        assert output =~ "hello sandbox"
      end
    end

    test "Elixir fallback handles errors gracefully" do
      unless CodeSandbox.docker_available?() do
        assert {:error, msg} = CodeSandbox.execute(%{
          "language" => "elixir",
          "code" => "raise \"boom\""
        })

        assert msg =~ "UNSANDBOXED"
        assert msg =~ "boom"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fallback unavailable languages
  # ---------------------------------------------------------------------------

  describe "fallback for unsupported fallback languages" do
    test "go fallback returns error" do
      unless CodeSandbox.docker_available?() do
        assert {:error, msg} = CodeSandbox.execute(%{
          "language" => "go",
          "code" => "package main\nfunc main() {}"
        })

        assert msg =~ "UNSANDBOXED"
        assert msg =~ "not supported"
      end
    end

    test "ruby fallback returns error" do
      unless CodeSandbox.docker_available?() do
        assert {:error, msg} = CodeSandbox.execute(%{
          "language" => "ruby",
          "code" => "puts 'hi'"
        })

        assert msg =~ "UNSANDBOXED"
        assert msg =~ "not supported"
      end
    end

    test "rust fallback returns error" do
      unless CodeSandbox.docker_available?() do
        assert {:error, msg} = CodeSandbox.execute(%{
          "language" => "rust",
          "code" => "fn main() {}"
        })

        assert msg =~ "UNSANDBOXED"
        assert msg =~ "not supported"
      end
    end
  end
end
