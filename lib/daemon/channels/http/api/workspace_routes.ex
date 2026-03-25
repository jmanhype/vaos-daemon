defmodule Daemon.Channels.HTTP.API.WorkspaceRoutes do
  @moduledoc """
  Workspace introspection routes.

  Forwarded from /workspace in the parent API router.

  Effective endpoints:
    GET /workspace  (forwarded as GET /)
      Returns:
        - cwd         : current working directory
        - git_status  : short git status lines (empty list when not a git repo)
        - git_log     : last 5 commit oneline summaries (empty list when not a git repo)
        - directories : top-level directory names in cwd
        - files       : top-level regular file names in cwd
  """
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  plug :match
  plug :dispatch

  # ── GET / ─────────────────────────────────────────────────────────────────

  get "/" do
    cwd = File.cwd!()

    {git_status, git_log} = fetch_git_info(cwd)

    {dirs, files} =
      try do
        entries = File.ls!(cwd)

        Enum.split_with(entries, fn name ->
          File.dir?(Path.join(cwd, name))
        end)
      rescue
        e ->
          Logger.warning("[WorkspaceRoutes] Failed to list directory #{cwd}: #{Exception.message(e)}")
          {[], []}
      end

    body =
      Jason.encode!(%{
        cwd: cwd,
        git_status: git_status,
        git_log: git_log,
        directories: Enum.sort(dirs),
        files: Enum.sort(files)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  match _ do
    json_error(conn, 404, "not_found", "Workspace endpoint not found")
  end

  # ── Private ───────────────────────────────────────────────────────────────

  # Run git commands in the given directory. Returns {status_lines, log_lines}.
  # Both lists are empty when git is not available or the directory is not a git repo.
  defp fetch_git_info(cwd) do
    status_lines = run_git(cwd, ["status", "--short"])
    log_lines = run_git(cwd, ["log", "--oneline", "-5"])
    {status_lines, log_lines}
  end

  defp run_git(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: false) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {_, _code} ->
        []
    end
  rescue
    # git not on PATH, or any other OS-level error
    e ->
      Logger.debug("[WorkspaceRoutes] git command failed: #{Exception.message(e)}")
      []
  end
end
