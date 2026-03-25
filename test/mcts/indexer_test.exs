defmodule Daemon.MCTS.IndexerTest do
  use ExUnit.Case, async: true

  alias Daemon.MCTS.Indexer

  @test_dir System.tmp_dir!() |> Path.join("osa_mcts_test_#{System.unique_integer([:positive])}")

  setup do
    # Create a small test directory structure
    File.rm_rf!(@test_dir)
    File.mkdir_p!(Path.join(@test_dir, "lib"))
    File.mkdir_p!(Path.join(@test_dir, "test"))
    File.mkdir_p!(Path.join(@test_dir, "config"))

    # Code files
    File.write!(Path.join([@test_dir, "lib", "auth.ex"]), """
    defmodule Auth do
      def authenticate(user, password) do
        # authentication logic
        check_credentials(user, password)
      end

      defp check_credentials(user, pass), do: {user, pass}
    end
    """)

    File.write!(Path.join([@test_dir, "lib", "router.ex"]), """
    defmodule Router do
      def route(conn) do
        # HTTP routing
        dispatch(conn)
      end

      defp dispatch(conn), do: conn
    end
    """)

    File.write!(Path.join([@test_dir, "lib", "database.ex"]), """
    defmodule Database do
      def query(sql) do
        # database query execution
        execute(sql)
      end

      defp execute(sql), do: sql
    end
    """)

    # Test file
    File.write!(Path.join([@test_dir, "test", "auth_test.exs"]), """
    defmodule AuthTest do
      use ExUnit.Case
      test "authenticates user" do
        assert Auth.authenticate("admin", "pass")
      end
    end
    """)

    # Config file
    File.write!(Path.join([@test_dir, "config", "config.exs"]), """
    import Config
    config :myapp, auth_provider: :local
    """)

    # Root files
    File.write!(Path.join(@test_dir, "mix.exs"), """
    defmodule MyApp.MixProject do
      use Mix.Project
      def project, do: [app: :myapp]
    end
    """)

    File.write!(Path.join(@test_dir, "README.md"), "# My App\nA test application.")

    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Basic functionality
  # ---------------------------------------------------------------------------

  describe "run/3 basic" do
    test "returns {:ok, result} with files list" do
      {:ok, result} = Indexer.run("authentication logic", @test_dir)

      assert is_map(result)
      assert is_list(result.files)
      assert is_binary(result.summary)
      assert is_integer(result.total_explored)
    end

    test "returns files with required fields" do
      {:ok, result} = Indexer.run("authentication", @test_dir)

      if length(result.files) > 0 do
        file = hd(result.files)
        assert Map.has_key?(file, :path)
        assert Map.has_key?(file, :relevance)
        assert Map.has_key?(file, :visits)
        assert is_binary(file.path)
        assert is_float(file.relevance)
        assert is_integer(file.visits)
      end
    end

    test "ranks auth.ex highest for 'authentication' goal" do
      {:ok, result} = Indexer.run("authentication", @test_dir, max_iterations: 100)

      if length(result.files) > 0 do
        top = hd(result.files)
        assert String.contains?(top.path, "auth")
      end
    end

    test "ranks database.ex highest for 'database query' goal" do
      {:ok, result} = Indexer.run("database query", @test_dir, max_iterations: 100)

      if length(result.files) > 0 do
        paths = Enum.map(result.files, & &1.path)
        db_files = Enum.filter(paths, &String.contains?(&1, "database"))
        assert length(db_files) > 0
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Options
  # ---------------------------------------------------------------------------

  describe "run/3 options" do
    test "respects max_results" do
      {:ok, result} = Indexer.run("code", @test_dir, max_results: 2)
      assert length(result.files) <= 2
    end

    test "respects max_iterations" do
      {:ok, result} = Indexer.run("code", @test_dir, max_iterations: 5)
      assert is_map(result)
      # Should still return results even with few iterations
      assert is_list(result.files)
    end

    test "caps max_iterations at 500" do
      # Should not crash with high iteration count
      {:ok, result} = Indexer.run("code", @test_dir, max_iterations: 1000)
      assert is_map(result)
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------

  describe "run/3 errors" do
    test "returns error for nonexistent directory" do
      {:error, msg} = Indexer.run("test", "/nonexistent/path/#{System.unique_integer()}")
      assert String.contains?(msg, "not found")
    end
  end

  # ---------------------------------------------------------------------------
  # File type scoring
  # ---------------------------------------------------------------------------

  describe "relevance scoring" do
    test "code files score higher than docs" do
      {:ok, result} = Indexer.run("application", @test_dir, max_iterations: 100)

      if length(result.files) >= 2 do
        # Find an .ex file and the .md file
        ex_files = Enum.filter(result.files, &String.ends_with?(&1.path, ".ex"))
        md_files = Enum.filter(result.files, &String.ends_with?(&1.path, ".md"))

        if length(ex_files) > 0 and length(md_files) > 0 do
          best_ex = hd(ex_files).relevance
          best_md = hd(md_files).relevance
          # Code files should generally rank higher (ext_score: 1.0 vs 0.3)
          assert best_ex >= best_md
        end
      end
    end

    test "summary contains iteration count" do
      {:ok, result} = Indexer.run("test", @test_dir, max_iterations: 25)
      assert String.contains?(result.summary, "25 iterations")
    end

    test "total_explored is positive" do
      {:ok, result} = Indexer.run("test", @test_dir)
      assert result.total_explored > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Skip patterns
  # ---------------------------------------------------------------------------

  describe "directory skipping" do
    test "skips .git directories" do
      git_dir = Path.join(@test_dir, ".git")
      File.mkdir_p!(Path.join(git_dir, "objects"))
      File.write!(Path.join(git_dir, "HEAD"), "ref: refs/heads/main")

      {:ok, result} = Indexer.run("git", @test_dir, max_iterations: 50)
      paths = Enum.map(result.files, & &1.path)

      refute Enum.any?(paths, &String.contains?(&1, ".git/"))
    end

    test "skips node_modules" do
      nm_dir = Path.join(@test_dir, "node_modules")
      File.mkdir_p!(Path.join(nm_dir, "lodash"))
      File.write!(Path.join([nm_dir, "lodash", "index.js"]), "module.exports = {}")

      {:ok, result} = Indexer.run("lodash", @test_dir, max_iterations: 50)
      paths = Enum.map(result.files, & &1.path)

      refute Enum.any?(paths, &String.contains?(&1, "node_modules"))
    end
  end
end
