defmodule Daemon.Agent.Orchestrator.GitVersioning do
  @moduledoc """
  Automatic git versioning for orchestrated tasks.

  Creates a checkpoint commit before a task runs and an outcome commit
  after it completes. This gives every orchestrated task a clean
  before/after diff in the workspace repo history.

  ## Flow

      checkpoint/2  →  agents run  →  commit_outcome/3

  Both functions are best-effort — they log warnings on failure but
  never crash the calling orchestrator.

  ## Workspace

  Operates on the configured workspace path
  (`Application.get_env(:daemon, :workspace_path, "~/.daemon/workspace")`).
  Only runs if the workspace is a git repository.
  """

  require Logger

  alias Daemon.Tools.Builtins.Git

  @doc """
  Create a WIP checkpoint commit before a task starts.

  Stages all changes in the workspace and commits with a message like:
  `chore(osa): checkpoint before <task_id>`

  Returns `:ok` on success or `:skip` if the workspace is not a git repo
  or has nothing to commit.
  """
  @spec checkpoint(String.t(), String.t()) :: :ok | :skip
  def checkpoint(task_id, workspace_path \\ workspace()) do
    path = Path.expand(workspace_path)

    unless git_repo?(path) do
      :skip
    else
      case Git.execute(%{
             "operation" => "status",
             "path" => path
           }) do
        {:ok, status} when status == "(no output)" ->
          Logger.debug("[GitVersioning] Nothing to checkpoint for task #{task_id}")
          :skip

        {:ok, _status} ->
          msg = "chore(osa): checkpoint before #{task_id}"
          commit(path, msg, task_id, "checkpoint")

        {:error, reason} ->
          Logger.warning("[GitVersioning] git status failed: #{reason}")
          :skip
      end
    end
  end

  @doc """
  Commit the outcome of a completed task.

  Stages all changes and commits with a message like:
  `feat(osa): <task_summary> [task:<task_id>]`

  Returns `:ok` or `:skip`.
  """
  @spec commit_outcome(String.t(), String.t(), String.t()) :: :ok | :skip
  def commit_outcome(task_id, summary, workspace_path \\ workspace()) do
    path = Path.expand(workspace_path)

    unless git_repo?(path) do
      :skip
    else
      safe_summary =
        summary
        |> String.replace(~r/\s+/, " ")
        |> String.slice(0, 72)

      msg = "feat(osa): #{safe_summary} [task:#{task_id}]"
      commit(path, msg, task_id, "outcome")
    end
  end

  @doc """
  Return recent git log for the workspace as a string.
  Useful for injecting git context into agent prompts.
  """
  @spec recent_log(String.t(), non_neg_integer()) :: String.t()
  def recent_log(workspace_path \\ workspace(), count \\ 10) do
    path = Path.expand(workspace_path)

    if git_repo?(path) do
      case Git.execute(%{"operation" => "log", "path" => path, "count" => count}) do
        {:ok, log} -> log
        {:error, _} -> "(git log unavailable)"
      end
    else
      "(not a git repository)"
    end
  end

  @doc """
  Return current git status for the workspace as a string.
  """
  @spec current_status(String.t()) :: String.t()
  def current_status(workspace_path \\ workspace()) do
    path = Path.expand(workspace_path)

    if git_repo?(path) do
      case Git.execute(%{"operation" => "status", "path" => path}) do
        {:ok, status} -> status
        {:error, _} -> "(git status unavailable)"
      end
    else
      "(not a git repository)"
    end
  end

  # --- Private ---

  defp commit(path, message, task_id, phase) do
    # Use "add" with files=["-u"] so only already-tracked files are staged.
    # This prevents accidentally committing secrets, temp files, or .env files
    # that land in the workspace but were never explicitly git-added.
    with {:ok, _} <- Git.execute(%{"operation" => "add", "path" => path, "files" => ["-u"]}),
         {:ok, result} <- Git.execute(%{"operation" => "commit", "path" => path, "message" => message}) do
      Logger.info("[GitVersioning] #{phase} commit for task #{task_id}: #{String.slice(result, 0, 80)}")
      :ok
    else
      {:error, reason} ->
        if String.contains?(reason, "nothing to commit") do
          Logger.debug("[GitVersioning] Nothing to commit for #{phase} of task #{task_id}")
          :skip
        else
          Logger.warning("[GitVersioning] #{phase} commit failed for task #{task_id}: #{reason}")
          :skip
        end
    end
  end

  defp git_repo?(path) do
    File.dir?(path) and File.dir?(Path.join(path, ".git"))
  end

  defp workspace do
    Application.get_env(:daemon, :workspace_path, "~/.daemon/workspace")
  end
end
