defmodule OptimalSystemAgent.Agent.Orchestrator.Explorer do
  @moduledoc """
  Codebase exploration phase for the Orchestrator (Wave 0).

  Always runs before any other agent. Maps the repository so downstream
  agents have concrete knowledge instead of guesses.

  Covers:
  - Git history and current working-tree state
  - Tech stack identification
  - Directory structure of relevant source paths
  - Task-relevant files (read and summarised)
  - Patterns and conventions observed

  Output is injected as dependency context into every Wave-1+ agent via
  `Decomposer.build_dependency_context/2`.
  """

  alias OptimalSystemAgent.Agent.Orchestrator.SubTask

  # git tool is used for read-only git operations (status, log, diff, show, stash)
  # code_symbols extracts def/module/struct/func without reading full file content
  @explore_tools ["dir_list", "file_glob", "file_read", "file_grep", "git", "code_symbols"]

  @doc """
  Prepend an explore sub-task to `sub_tasks` and wire its output as a
  dependency for all tasks that currently have no dependencies (Wave 0).
  """
  @spec inject_explore_phase([SubTask.t()], String.t()) :: [SubTask.t()]
  def inject_explore_phase(sub_tasks, original_message) do
    explore = build_explore_subtask(original_message)

    updated =
      Enum.map(sub_tasks, fn st ->
        if st.depends_on == [] do
          %{st | depends_on: ["explore"]}
        else
          st
        end
      end)

    [explore | updated]
  end

  @doc """
  Build the Wave-0 explore sub-task for the given task message.
  """
  @spec build_explore_subtask(String.t()) :: SubTask.t()
  def build_explore_subtask(task_message) do
    task_preview = String.slice(task_message, 0, 400)

    %SubTask{
      name: "explore",
      description: """
      ## Role: EXPLORER (Wave 0 — runs before everything else)

      Task you are preparing for:
      > #{task_preview}

      ## Phase 1 — Git context (read-only, use the `git` tool)
      - git operation=log count=20        → recent commit history
      - git operation=status              → working-tree state (M/A/D/?)
      - git operation=diff ref=HEAD~3     → what changed in the last 3 commits
      - git operation=stash stash_action=list → any stashed work in progress

      ## Phase 2 — Project structure
      - dir_list the root → identify tech stack files (mix.exs, package.json, go.mod, Cargo.toml, Dockerfile, etc.)
      - dir_list the primary source dirs (lib/, src/, internal/, app/, etc.)
      - file_glob relevant file patterns based on the task keywords
      - code_symbols on the source root → get a full symbol map (module/def/struct/func at file:line)
        without reading individual files. Use this to find where task-relevant symbols are defined.

      ## Phase 3 — Key file content
      - Read only the files that code_symbols or file_grep identified as relevant
      - Read the project's primary config file (mix.exs / package.json / go.mod)
      - file_grep for any remaining symbol names mentioned in the task that code_symbols missed

      ## Phase 4 — Output
      Produce a structured codebase map using exactly these headings:

      ## Git State
      [recent commits + modified files + any stash]

      ## Stack
      [language, framework, key libraries, OTP/runtime version if visible]

      ## Structure
      [relevant dirs and what lives in each one]

      ## Files Relevant to This Task
      [path] — [one-line description of what it does and why it matters]

      ## Patterns & Conventions
      [naming, module layout, error handling, test structure, etc.]

      ## Watch-Outs for Downstream Agents
      [gotchas, existing abstractions to reuse, areas of active change from git]
      """,
      role: :explorer,
      tools_needed: @explore_tools,
      depends_on: []
    }
  end
end
