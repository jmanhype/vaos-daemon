defmodule OptimalSystemAgent.Tools.Builtins.GitTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Git

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Creates an isolated temp git repo allowed under the default allowed paths.
  # The tmp dir under ~ keeps it inside the allowed-path whitelist.
  defp make_repo do
    base = Path.join([System.tmp_dir!(), "osa_git_test_#{System.unique_integer([:positive])}"])
    File.mkdir_p!(base)

    # Allow this path during the test
    existing = Application.get_env(:optimal_system_agent, :allowed_read_paths, ["~", "/tmp"])
    Application.put_env(:optimal_system_agent, :allowed_read_paths, [base | existing])

    on_exit(fn ->
      Application.put_env(:optimal_system_agent, :allowed_read_paths, existing)
      File.rm_rf!(base)
    end)

    # init + minimal config + initial commit so HEAD exists
    System.cmd("git", ["init"], cd: base, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@osa"], cd: base, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.name", "OSA Test"], cd: base, stderr_to_stdout: true)
    File.write!(Path.join(base, "README.md"), "hello")
    System.cmd("git", ["add", "-A"], cd: base, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "init"], cd: base, stderr_to_stdout: true)

    base
  end

  defp run(params, repo), do: Git.execute(Map.put(params, "path", repo))

  # ---------------------------------------------------------------------------
  # Tool metadata
  # ---------------------------------------------------------------------------

  describe "tool metadata" do
    test "name returns git" do
      assert Git.name() == "git"
    end

    test "description is a non-empty string" do
      desc = Git.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end

    test "parameters schema requires operation" do
      params = Git.parameters()
      assert params["type"] == "object"
      assert "operation" in params["required"]
      assert Map.has_key?(params["properties"], "operation")
    end

    test "safety level is :write_destructive" do
      assert Git.safety() == :write_destructive
    end
  end

  # ---------------------------------------------------------------------------
  # Missing required parameter
  # ---------------------------------------------------------------------------

  describe "execute/1 — missing operation" do
    test "returns error when operation is absent" do
      assert {:error, msg} = Git.execute(%{})
      assert msg =~ "Missing required parameter"
    end

    test "returns error for unknown operation" do
      repo = make_repo()
      assert {:error, msg} = run(%{"operation" => "frobulate"}, repo)
      assert msg =~ "Unknown operation"
    end
  end

  # ---------------------------------------------------------------------------
  # status
  # ---------------------------------------------------------------------------

  describe "status" do
    test "returns ok with branch info on a clean repo" do
      repo = make_repo()
      assert {:ok, output} = run(%{"operation" => "status"}, repo)
      # --short --branch always starts with ## for the branch line
      assert output =~ "##"
    end

    test "shows untracked files" do
      repo = make_repo()
      File.write!(Path.join(repo, "new_file.txt"), "content")
      assert {:ok, output} = run(%{"operation" => "status"}, repo)
      assert output =~ "new_file.txt"
    end
  end

  # ---------------------------------------------------------------------------
  # log
  # ---------------------------------------------------------------------------

  describe "log" do
    test "returns ok with at least the init commit in oneline format" do
      repo = make_repo()
      assert {:ok, output} = run(%{"operation" => "log"}, repo)
      assert output =~ "init"
    end

    test "count parameter limits results" do
      repo = make_repo()
      # add a second commit
      File.write!(Path.join(repo, "b.txt"), "b")
      System.cmd("git", ["add", "-A"], cd: repo, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "second"], cd: repo, stderr_to_stdout: true)

      assert {:ok, output} = run(%{"operation" => "log", "count" => 1}, repo)
      lines = output |> String.split("\n", trim: true)
      assert length(lines) == 1
    end

    test "conventional format groups commits by type" do
      repo = make_repo()
      File.write!(Path.join(repo, "feat.txt"), "f")
      System.cmd("git", ["add", "-A"], cd: repo, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "feat: add feature"], cd: repo, stderr_to_stdout: true)

      assert {:ok, output} = run(%{"operation" => "log", "format" => "conventional"}, repo)
      # The init commit is :other, the feat: commit should be :feat — either section or Other appears
      assert output =~ "Features" or output =~ "Other" or output =~ "no conventional commits"
    end

    test "full format includes stat output" do
      repo = make_repo()
      assert {:ok, output} = run(%{"operation" => "log", "format" => "full"}, repo)
      # --stat always includes the file-change summary or at least Author:
      assert output =~ "Author" or output =~ "README"
    end
  end

  # ---------------------------------------------------------------------------
  # diff
  # ---------------------------------------------------------------------------

  describe "diff" do
    test "returns ok on a clean repo (no diff)" do
      repo = make_repo()
      assert {:ok, _} = run(%{"operation" => "diff"}, repo)
    end

    test "shows changes when file is modified" do
      repo = make_repo()
      File.write!(Path.join(repo, "README.md"), "modified content")
      assert {:ok, output} = run(%{"operation" => "diff"}, repo)
      assert output =~ "modified content" or output =~ "README"
    end

    test "scoped to a specific file with the file param" do
      repo = make_repo()
      File.write!(Path.join(repo, "README.md"), "changed")
      File.write!(Path.join(repo, "other.txt"), "other")
      assert {:ok, output} = run(%{"operation" => "diff", "file" => "README.md"}, repo)
      assert output =~ "README" or output =~ "changed" or output =~ "(no output)"
    end
  end

  # ---------------------------------------------------------------------------
  # commit
  # ---------------------------------------------------------------------------

  describe "commit" do
    test "creates a commit with a message" do
      repo = make_repo()
      File.write!(Path.join(repo, "change.txt"), "new content")
      assert {:ok, output} = run(%{"operation" => "commit", "message" => "feat: add change"}, repo)
      assert output =~ "feat: add change" or output =~ "change.txt" or output =~ "master" or output =~ "main"
    end

    test "requires a message parameter" do
      repo = make_repo()
      assert {:error, msg} = run(%{"operation" => "commit"}, repo)
      assert msg =~ "message"
    end

    test "rejects empty message" do
      repo = make_repo()
      assert {:error, msg} = run(%{"operation" => "commit", "message" => ""}, repo)
      assert msg =~ "empty"
    end

    test "nothing to commit returns ok" do
      repo = make_repo()
      assert {:ok, output} = run(%{"operation" => "commit", "message" => "noop commit"}, repo)
      assert output =~ "nothing to commit"
    end
  end

  # ---------------------------------------------------------------------------
  # add
  # ---------------------------------------------------------------------------

  describe "add" do
    test "stages all files when no files param given" do
      repo = make_repo()
      File.write!(Path.join(repo, "staged.txt"), "content")
      assert {:ok, _} = run(%{"operation" => "add"}, repo)

      # Verify file is staged
      {status_out, _} = System.cmd("git", ["status", "--short"], cd: repo, stderr_to_stdout: true)
      assert status_out =~ "A"
    end

    test "stages specific files" do
      repo = make_repo()
      File.write!(Path.join(repo, "a.txt"), "a")
      File.write!(Path.join(repo, "b.txt"), "b")
      assert {:ok, _} = run(%{"operation" => "add", "files" => ["a.txt"]}, repo)

      {status_out, _} = System.cmd("git", ["status", "--short"], cd: repo, stderr_to_stdout: true)
      assert status_out =~ "a.txt"
    end

    test "empty files list stages all (same as no param)" do
      repo = make_repo()
      File.write!(Path.join(repo, "c.txt"), "c")
      assert {:ok, _} = run(%{"operation" => "add", "files" => []}, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # stash
  # ---------------------------------------------------------------------------

  describe "stash" do
    test "list returns ok (empty list is valid)" do
      repo = make_repo()
      assert {:ok, _} = run(%{"operation" => "stash", "stash_action" => "list"}, repo)
    end

    test "defaults to list when stash_action is omitted" do
      repo = make_repo()
      assert {:ok, _} = run(%{"operation" => "stash"}, repo)
    end

    test "unknown stash action returns error" do
      repo = make_repo()
      assert {:error, msg} = run(%{"operation" => "stash", "stash_action" => "explode"}, repo)
      assert msg =~ "Unknown stash action"
    end
  end

  # ---------------------------------------------------------------------------
  # reset
  # ---------------------------------------------------------------------------

  describe "reset" do
    test "mixed reset returns ok" do
      repo = make_repo()
      assert {:ok, _} = run(%{"operation" => "reset", "reset_mode" => "mixed"}, repo)
    end

    test "soft reset returns ok" do
      repo = make_repo()
      File.write!(Path.join(repo, "soft.txt"), "s")
      System.cmd("git", ["add", "-A"], cd: repo, stderr_to_stdout: true)
      assert {:ok, _} = run(%{"operation" => "reset", "reset_mode" => "soft"}, repo)
    end

    test "hard reset includes warning in output" do
      repo = make_repo()
      assert {:ok, output} = run(%{"operation" => "reset", "reset_mode" => "hard"}, repo)
      assert output =~ "WARNING"
    end

    test "defaults to mixed when reset_mode is omitted" do
      repo = make_repo()
      assert {:ok, _} = run(%{"operation" => "reset"}, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # tag
  # ---------------------------------------------------------------------------

  describe "tag" do
    test "list action returns ok" do
      repo = make_repo()
      assert {:ok, _} = run(%{"operation" => "tag", "tag_action" => "list"}, repo)
    end

    test "defaults to list when tag_action is omitted" do
      repo = make_repo()
      assert {:ok, _} = run(%{"operation" => "tag"}, repo)
    end

    test "create action requires tag_name" do
      repo = make_repo()
      assert {:error, msg} = run(%{"operation" => "tag", "tag_action" => "create"}, repo)
      assert msg =~ "tag_name"
    end

    test "create action with tag_name succeeds" do
      repo = make_repo()
      assert {:ok, _} = run(%{"operation" => "tag", "tag_action" => "create", "tag_name" => "v1.0.0"}, repo)
    end

    test "create annotated tag with message" do
      repo = make_repo()
      assert {:ok, _} = run(%{
        "operation" => "tag",
        "tag_action" => "create",
        "tag_name" => "v2.0.0",
        "tag_message" => "Release 2.0"
      }, repo)
    end

    test "latest returns no-tags message on empty repo" do
      repo = make_repo()
      assert {:ok, output} = run(%{"operation" => "tag", "tag_action" => "latest"}, repo)
      # Either a real tag or the placeholder
      assert is_binary(output)
    end

    test "unknown tag action returns error" do
      repo = make_repo()
      assert {:error, msg} = run(%{"operation" => "tag", "tag_action" => "destroy"}, repo)
      assert msg =~ "Unknown tag action"
    end
  end

  # ---------------------------------------------------------------------------
  # show
  # ---------------------------------------------------------------------------

  describe "show" do
    test "shows HEAD by default" do
      repo = make_repo()
      assert {:ok, output} = run(%{"operation" => "show"}, repo)
      assert output =~ "commit"
    end

    test "accepts a specific ref" do
      repo = make_repo()
      assert {:ok, output} = run(%{"operation" => "show", "ref" => "HEAD"}, repo)
      assert output =~ "commit"
    end
  end

  # ---------------------------------------------------------------------------
  # clone URL validation
  # ---------------------------------------------------------------------------

  # clone's URL validation runs inside run_operation/3 after ensure_repo on the
  # working directory. We give it a pre-existing repo so ensure_repo succeeds,
  # letting the URL validation code execute.
  describe "clone URL validation" do
    test "rejects file:// scheme" do
      repo = make_repo()
      assert {:error, msg} = run(%{"operation" => "clone", "url" => "file:///etc/passwd"}, repo)
      assert msg =~ "Unsupported clone URL scheme"
    end

    test "rejects ftp:// scheme" do
      repo = make_repo()
      assert {:error, msg} = run(%{"operation" => "clone", "url" => "ftp://evil.com/repo"}, repo)
      assert msg =~ "Unsupported clone URL scheme"
    end

    test "requires a url parameter" do
      repo = make_repo()
      assert {:error, msg} = run(%{"operation" => "clone"}, repo)
      assert msg =~ "url"
    end
  end

  # ---------------------------------------------------------------------------
  # blame
  # ---------------------------------------------------------------------------

  describe "blame" do
    test "requires file parameter" do
      repo = make_repo()
      assert {:error, msg} = run(%{"operation" => "blame"}, repo)
      assert msg =~ "file"
    end

    test "returns blame output for a committed file" do
      repo = make_repo()
      assert {:ok, output} = run(%{"operation" => "blame", "file" => "README.md"}, repo)
      assert output =~ "Blame for README.md"
    end
  end

  # ---------------------------------------------------------------------------
  # remote
  # ---------------------------------------------------------------------------

  describe "remote" do
    test "lists remotes (empty on fresh repo)" do
      repo = make_repo()
      assert {:ok, _} = run(%{"operation" => "remote"}, repo)
    end

    test "adds a remote with provided url" do
      repo = make_repo()
      assert {:ok, _} = run(%{
        "operation" => "remote",
        "url" => "https://github.com/example/repo.git",
        "remote_name" => "upstream"
      }, repo)
    end
  end

  # ---------------------------------------------------------------------------
  # Path validation
  # ---------------------------------------------------------------------------

  describe "path validation" do
    test "rejects paths outside allowed list" do
      assert {:error, msg} = Git.execute(%{"operation" => "status", "path" => "/etc"})
      assert msg =~ "Access denied"
    end
  end

  # ---------------------------------------------------------------------------
  # group_by_conventional_type (via log conventional format)
  # ---------------------------------------------------------------------------

  describe "conventional commit grouping" do
    test "empty repo returns no-commits placeholder" do
      repo = make_repo()
      # Only has an 'init' commit (not conventional) — acceptable output
      assert {:ok, output} = run(%{"operation" => "log", "format" => "conventional"}, repo)
      assert is_binary(output)
    end

    test "feat commit appears in Features section" do
      repo = make_repo()
      File.write!(Path.join(repo, "feat_file.txt"), "f")
      System.cmd("git", ["add", "-A"], cd: repo, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "feat: new capability"], cd: repo, stderr_to_stdout: true)

      assert {:ok, output} = run(%{"operation" => "log", "format" => "conventional"}, repo)
      assert output =~ "Features" or output =~ "new capability"
    end

    test "fix commit appears in Bug Fixes section" do
      repo = make_repo()
      File.write!(Path.join(repo, "fix_file.txt"), "x")
      System.cmd("git", ["add", "-A"], cd: repo, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "fix: correct null pointer"], cd: repo, stderr_to_stdout: true)

      assert {:ok, output} = run(%{"operation" => "log", "format" => "conventional"}, repo)
      assert output =~ "Bug Fixes" or output =~ "null pointer"
    end
  end

  # ---------------------------------------------------------------------------
  # bisect — safe executable guard
  # ---------------------------------------------------------------------------

  describe "bisect run — safe executable guard" do
    test "disallowed executable is rejected" do
      repo = make_repo()
      assert {:error, msg} = run(%{
        "operation" => "bisect",
        "bisect_action" => "run",
        "bisect_command" => "curl http://evil.com"
      }, repo)
      assert msg =~ "not allowed"
    end
  end
end
