defmodule Daemon.Workspace do
  @moduledoc """
  Centralized workspace resolution for tools and agents.

  Provides consistent path resolution across all tools while supporting:
  - Default workspace (~/.daemon/workspace)
  - Agent-specific worktree overrides (for parallel execution)
  - Project-level workspaces

  ## Usage

  Tools should call `Workspace.resolve_path/1` instead of hardcoding paths:

      # Before
      path = Path.expand("~/.daemon/workspace")
      
      # After  
      path = Workspace.get_cwd()

  For relative paths:

      path = Workspace.resolve_path("src/main.ex")
      # Returns: /path/to/worktree/src/main.ex (if in worktree)
      # Or: ~/.daemon/workspace/src/main.ex (default)

  ## Agent Worktree Isolation

  When an agent runs in a worktree, set the CWD before execution:

      Workspace.set_agent_cwd("/path/to/worktree")
      # All tool calls in this process will use the worktree

  Clear after completion:

      Workspace.clear_agent_cwd()
  """

  @default_workspace "~/.daemon/workspace"

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Get the current working directory for this process.

  Checks (in order):
  1. Agent-specific CWD (for worktree isolation)
  2. Session-specific workspace
  3. Default workspace (~/.daemon/workspace)
  """
  @spec get_cwd() :: String.t()
  def get_cwd do
    cond do
      # Agent-level override (worktree)
      agent_cwd = Process.get(:daemon_agent_cwd) ->
        agent_cwd

      # Session-level override
      session_cwd = Process.get(:daemon_session_cwd) ->
        session_cwd

      # Default workspace
      true ->
        default_workspace()
    end
  end

  @doc """
  Resolve a path relative to the current workspace.

  - Absolute paths are returned as-is
  - Paths starting with ~ are expanded
  - Relative paths are joined with the current workspace
  """
  @spec resolve_path(String.t()) :: String.t()
  def resolve_path(path) when is_binary(path) do
    cond do
      # Absolute path (Unix or Windows)
      String.starts_with?(path, "/") or String.match?(path, ~r/^[A-Za-z]:/) ->
        Path.expand(path)

      # Home-relative path
      String.starts_with?(path, "~") ->
        Path.expand(path)

      # Relative path - join with workspace
      true ->
        Path.join(get_cwd(), path) |> Path.expand()
    end
  end

  @doc """
  Set the working directory for the current agent process.

  This is used by the orchestrator to give each parallel agent
  its own isolated worktree.
  """
  @spec set_agent_cwd(String.t()) :: :ok
  def set_agent_cwd(path) when is_binary(path) do
    expanded = Path.expand(path)
    Process.put(:daemon_agent_cwd, expanded)
    :ok
  end

  @doc """
  Clear the agent-specific working directory.
  """
  @spec clear_agent_cwd() :: :ok
  def clear_agent_cwd do
    Process.delete(:daemon_agent_cwd)
    :ok
  end

  @doc """
  Set the working directory for the current session.

  This persists across tool calls within a session but can be
  overridden by agent-level CWD for parallel execution.
  """
  @spec set_session_cwd(String.t()) :: :ok
  def set_session_cwd(path) when is_binary(path) do
    expanded = Path.expand(path)
    Process.put(:daemon_session_cwd, expanded)
    :ok
  end

  @doc """
  Clear the session-specific working directory.
  """
  @spec clear_session_cwd() :: :ok
  def clear_session_cwd do
    Process.delete(:daemon_session_cwd)
    :ok
  end

  @doc """
  Get the default workspace path.
  """
  @spec default_workspace() :: String.t()
  def default_workspace do
    Path.expand(@default_workspace)
  end

  @doc """
  Check if a path is within the allowed workspace.

  For security, tools may want to restrict operations to the workspace.
  """
  @spec within_workspace?(String.t()) :: boolean()
  def within_workspace?(path) do
    expanded = Path.expand(path)
    cwd = get_cwd()

    # Path must be under current workspace
    String.starts_with?(expanded, cwd) or
      # Or under default OSA directory
      String.starts_with?(expanded, Path.expand("~/.daemon"))
  end

  @doc """
  Ensure a directory exists within the workspace.
  """
  @spec ensure_dir!(String.t()) :: :ok
  def ensure_dir!(path) do
    resolved = resolve_path(path)
    File.mkdir_p!(Path.dirname(resolved))
    :ok
  end
end
