defmodule OptimalSystemAgent.Agent.Orchestrator.SkillManager do
  @moduledoc """
  Dynamic skill creation and discovery for the orchestrator.

  Skills are SKILL.md files persisted to `~/.osa/skills/<name>/`.
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Tools.Registry, as: Tools

  @doc """
  Create a new skill file at `~/.osa/skills/<name>/SKILL.md`.

  Returns `{:ok, name}` or `{:error, reason}`.
  """
  @spec create(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def create(name, description, instructions, tools) do
    skill_dir = Path.expand("~/.osa/skills/#{name}")

    try do
      File.mkdir_p!(skill_dir)

      tools_yaml =
        case tools do
          [] -> ""
          list -> Enum.map_join(list, "\n", fn t -> "  - #{t}" end)
        end

      skill_content = """
      ---
      name: #{name}
      description: #{description}
      tools:
      #{tools_yaml}
      ---

      ## Instructions

      #{instructions}
      """

      skill_path = Path.join(skill_dir, "SKILL.md")
      File.write!(skill_path, skill_content)

      Logger.info("[Orchestrator] Created new skill file: #{skill_path}")

      Bus.emit(:system_event, %{
        event: :orchestrator_skill_created,
        name: name,
        description: description,
        path: skill_path
      })

      {:ok, name}
    rescue
      e ->
        Logger.error("[Orchestrator] Failed to create skill #{name}: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  @doc """
  Search for existing skills matching a task description.

  Returns `{:matches, [%{name, description, relevance}]}` or `:no_matches`.
  """
  @spec find_matches(String.t()) :: {:matches, [map()]} | :no_matches
  def find_matches(task_description) do
    search_results = Tools.search(task_description)

    if search_results == [] do
      :no_matches
    else
      matches =
        Enum.map(search_results, fn {name, description, relevance} ->
          %{name: name, description: description, relevance: relevance}
        end)

      {:matches, matches}
    end
  end
end
