defmodule OptimalSystemAgent.Tools.Builtins.Git do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @default_allowed_paths ["~", "/tmp"]

  @impl true
  def name, do: "git"

  @impl true
  def description,
    do:
      "Run git operations in a repository: status, diff, log, commit, branch, show, stash. " <>
        "Safe — runs specific git subcommands only, no arbitrary shell execution."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "operation" => %{
          "type" => "string",
          "enum" => ["status", "diff", "log", "commit", "branch", "show", "stash"],
          "description" =>
            "Git operation: status (working tree), diff (changes), log (history), " <>
              "commit (stage all + commit), branch (list or create), show (inspect ref), stash (push/pop/list)"
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Working directory (git repo root). Defaults to ~/.osa/workspace if it exists, else ~."
        },
        "message" => %{
          "type" => "string",
          "description" => "Commit message (required for commit operation)"
        },
        "file" => %{
          "type" => "string",
          "description" => "File path for diff (relative or absolute). Omit to diff all changes."
        },
        "count" => %{
          "type" => "integer",
          "description" => "Number of log entries to show (for log operation, default: 15)"
        },
        "ref" => %{
          "type" => "string",
          "description" => "Git ref or commit hash to inspect (for show operation, default: HEAD)"
        },
        "branch_name" => %{
          "type" => "string",
          "description" => "Branch name to create and checkout (for branch operation)"
        },
        "stash_action" => %{
          "type" => "string",
          "enum" => ["push", "pop", "list"],
          "description" => "Stash action (default: list)"
        }
      },
      "required" => ["operation"]
    }
  end

  @impl true
  def execute(%{"operation" => operation} = params) do
    work_dir = resolve_work_dir(params["path"])

    case validate_path(work_dir) do
      :ok -> run_operation(operation, work_dir, params)
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: operation"}

  # --- Operations ---

  defp run_operation("status", dir, _params) do
    git(["status", "--short", "--branch"], dir)
  end

  defp run_operation("diff", dir, params) do
    args =
      case params["file"] do
        nil -> ["diff"]
        file -> ["diff", "--", file]
      end

    git(args, dir)
  end

  defp run_operation("log", dir, params) do
    count = params["count"] || 15
    git(["log", "--oneline", "--graph", "-#{count}"], dir)
  end

  defp run_operation("commit", dir, params) do
    case params["message"] do
      nil ->
        {:error, "commit requires a message parameter"}

      "" ->
        {:error, "commit message cannot be empty"}

      message ->
        # Stage all tracked + new files, then commit
        case git(["add", "-A"], dir) do
          {:ok, _} ->
            case git(["commit", "-m", message], dir) do
              {:ok, output} -> {:ok, output}
              # Nothing to commit is not a fatal error
              {:error, output} when output =~ "nothing to commit" -> {:ok, output}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, "git add failed: #{reason}"}
        end
    end
  end

  defp run_operation("branch", dir, params) do
    case params["branch_name"] do
      nil ->
        # List all branches with current highlighted
        git(["branch", "-a"], dir)

      name ->
        # Create and switch to new branch
        case git(["checkout", "-b", name], dir) do
          {:ok, output} -> {:ok, output}
          # Branch already exists — just switch
          {:error, _} -> git(["checkout", name], dir)
        end
    end
  end

  defp run_operation("show", dir, params) do
    ref = params["ref"] || "HEAD"
    git(["show", "--stat", ref], dir)
  end

  defp run_operation("stash", dir, params) do
    action = params["stash_action"] || "list"

    case action do
      "push" -> git(["stash", "push"], dir)
      "pop" -> git(["stash", "pop"], dir)
      "list" -> git(["stash", "list"], dir)
      other -> {:error, "Unknown stash action: #{other}. Use push, pop, or list."}
    end
  end

  defp run_operation(op, _dir, _params) do
    {:error, "Unknown operation: #{op}. Valid: status, diff, log, commit, branch, show, stash"}
  end

  # --- Helpers ---

  defp git(args, dir) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} ->
        out = String.trim(output)
        {:ok, if(out == "", do: "(no output)", else: out)}

      {output, _code} ->
        {:error, String.trim(output)}
    end
  rescue
    e -> {:error, "git command failed: #{Exception.message(e)}"}
  end

  defp resolve_work_dir(nil) do
    workspace = Path.expand("~/.osa/workspace")
    if File.dir?(workspace), do: workspace, else: Path.expand("~")
  end

  defp resolve_work_dir(path), do: Path.expand(path)

  defp validate_path(expanded_path) do
    allowed =
      Application.get_env(:optimal_system_agent, :allowed_read_paths, @default_allowed_paths)
      |> Enum.map(fn p ->
        e = Path.expand(p)
        if String.ends_with?(e, "/"), do: e, else: e <> "/"
      end)

    check =
      if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

    if Enum.any?(allowed, fn a -> String.starts_with?(check, a) end) do
      :ok
    else
      {:error, "Access denied: #{expanded_path} is outside allowed paths"}
    end
  end
end
