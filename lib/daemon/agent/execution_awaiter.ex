defmodule Daemon.Agent.ExecutionAwaiter do
  @moduledoc """
  Shared helper for awaiting real Orchestrator task completion.

  Orchestrator.execute returns {:ok, task_id} immediately — actual execution
  happens asynchronously via handle_continue. This module polls progress
  until the task actually completes, then verifies the git branch exists.

  Used by WorkDirector, InsightActuator, and ConvergenceEngine to replace
  the fire-and-forget pattern that was reporting false successes.
  """
  require Logger

  alias Daemon.Agent.Orchestrator

  @poll_interval_ms 10_000
  @default_timeout_ms :timer.minutes(10)

  @doc """
  Execute via Orchestrator and wait for real completion.

  Returns:
    {:ok, synthesis, branch} — task completed AND branch exists
    {:partial, synthesis}    — task completed but no branch created
    {:error, reason}         — task failed or timed out
  """
  @spec execute_and_await(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), String.t()} | {:partial, String.t()} | {:error, term()}
  def execute_and_await(prompt, session_id, branch, repo_path, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    strategy = Keyword.get(opts, :strategy, [])

    case Orchestrator.execute(prompt, session_id, strategy) do
      {:ok, task_id} ->
        Logger.debug("[ExecutionAwaiter] Task #{task_id} started, polling for completion...")
        deadline = System.monotonic_time(:millisecond) + timeout

        case poll_until_complete(task_id, deadline) do
          {:completed, synthesis} ->
            cond do
              not branch_exists?(branch, repo_path) ->
                Logger.warning("[ExecutionAwaiter] Task #{task_id} completed but branch #{branch} not found")
                {:partial, synthesis}

              not branch_has_commits?(branch, repo_path) ->
                Logger.warning("[ExecutionAwaiter] Task #{task_id} completed but branch #{branch} has 0 commits beyond main")
                {:error, {:empty_branch, synthesis}}

              true ->
                Logger.info("[ExecutionAwaiter] Task #{task_id} completed, branch #{branch} verified with commits")
                {:ok, synthesis, branch}
            end

          {:failed, error} ->
            {:error, {:orchestrator_failed, error}}

          {:timeout, last_status} ->
            {:error, {:timeout, last_status}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "Classify a failure reason into a structured failure class."
  @spec classify_failure(term()) :: atom()
  def classify_failure({:empty_branch, _}), do: :empty_branch
  def classify_failure({:orchestrator_failed, _}), do: :orchestrator_error
  def classify_failure({:timeout, _}), do: :timeout
  def classify_failure({:exception, msg}) when is_binary(msg) do
    cond do
      String.contains?(msg, "compile") -> :compilation_error
      String.contains?(msg, "test") -> :test_failure
      true -> :exception
    end
  end
  def classify_failure({:exit, _}), do: :process_crash
  def classify_failure(_), do: :unknown

  # -- Internal --

  defp poll_until_complete(task_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:timeout, :deadline_exceeded}
    else
      case Orchestrator.progress(task_id) do
        {:ok, %{status: :completed, synthesis: synthesis}} ->
          {:completed, synthesis || ""}

        {:ok, %{status: :failed, error: error}} ->
          {:failed, error}

        {:ok, %{status: status}} when status in [:running, :planning] ->
          Process.sleep(@poll_interval_ms)
          poll_until_complete(task_id, deadline)

        {:error, :not_found} ->
          {:failed, :task_not_found}

        _ ->
          Process.sleep(@poll_interval_ms)
          poll_until_complete(task_id, deadline)
      end
    end
  rescue
    _ -> {:failed, :poll_error}
  catch
    :exit, _ -> {:failed, :poll_exit}
  end

  defp branch_has_commits?(branch, repo_path) do
    case System.cmd("git", ["rev-list", "--count", "main..#{branch}"],
           cd: repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        count = output |> String.trim() |> String.to_integer()
        count > 0

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp branch_exists?(branch, repo_path) do
    case System.cmd("git", ["branch", "--list", branch], cd: repo_path, stderr_to_stdout: true) do
      {output, 0} when byte_size(output) > 0 -> true
      _ ->
        case System.cmd("git", ["ls-remote", "--heads", "origin", branch], cd: repo_path, stderr_to_stdout: true) do
          {output, 0} when byte_size(output) > 0 -> true
          _ -> false
        end
    end
  rescue
    _ -> false
  end
end
