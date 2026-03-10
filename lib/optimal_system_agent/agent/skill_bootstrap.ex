defmodule OptimalSystemAgent.Agent.SkillBootstrap do
  @moduledoc """
  Self-referential skill creation and immediate invocation.

  Allows OSA to create its own skill and then use it within the same session.
  The flow:

    1. `create_and_run/2` creates a SKILL.md via SkillManager
    2. The skill is registered into Tools.Registry (via reload_skills)
    3. A new agent session is opened
    4. The trigger message is sent into the session — the Registry injects
       the skill's instructions into the system prompt for that turn
    5. The agent executes the skill instructions with full tool access
    6. Returns `{:ok, %{skill_name, session_id, trigger_message}}`

  This demonstrates OSA's ability to author and immediately execute new
  capabilities without a restart or external intervention.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Orchestrator.SkillManager
  alias OptimalSystemAgent.SDK.Session

  @doc """
  Create a skill and immediately use it in a fresh agent session.

  ## Parameters

  - `skill_params` — map with keys:
    - `"name"` — kebab-case skill name
    - `"description"` — one-line description
    - `"instructions"` — full skill instructions (injected as system context)
    - `"triggers"` — list of trigger keywords (optional; defaults to [name])
    - `"tools"` — list of tool names the skill needs (optional)

  - `session_opts` — keyword list forwarded to `SDK.Session.create/1`
    - `:provider`, `:model`, `:user_id`, `:channel`

  ## Returns

  `{:ok, %{skill_name: name, session_id: sid, trigger_message: msg}}`
  or `{:error, reason}`.
  """
  @spec create_and_run(map(), keyword()) ::
          {:ok, %{skill_name: String.t(), session_id: String.t(), trigger_message: String.t()}}
          | {:error, term()}
  def create_and_run(skill_params, session_opts \\ []) do
    name = skill_params["name"]
    description = skill_params["description"] || ""
    instructions = skill_params["instructions"] || ""
    tools = skill_params["tools"] || []

    # Build triggers: use provided list or default to the skill name itself.
    raw_triggers = skill_params["triggers"] || [name]

    # Inject trigger list into instructions frontmatter via a custom field.
    # SkillManager.create/4 doesn't support triggers natively, so we write
    # the SKILL.md directly with the triggers field included.
    with {:ok, _} <- write_skill_with_triggers(name, description, instructions, tools, raw_triggers),
         :ok <- reload_registry(),
         {:ok, session_id} <- start_session(session_opts) do
      trigger_message = build_trigger_message(name, raw_triggers, description)
      dispatch_skill(session_id, trigger_message)

      Logger.info(
        "[SkillBootstrap] Skill '#{name}' created and dispatched → session #{session_id}"
      )

      {:ok,
       %{
         skill_name: name,
         session_id: session_id,
         trigger_message: trigger_message
       }}
    end
  end

  @doc """
  List all self-created skills (those under ~/.osa/skills/).
  Returns a list of skill name strings.
  """
  @spec list_self_skills() :: [String.t()]
  def list_self_skills do
    dir = Path.expand("~/.osa/skills")

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(fn entry ->
        skill_path = Path.join([dir, entry, "SKILL.md"])
        File.exists?(skill_path)
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  # ── Private ──────────────────────────────────────────────────────────

  # Write a SKILL.md with full YAML frontmatter including triggers.
  defp write_skill_with_triggers(name, description, instructions, tools, triggers) do
    skill_dir = Path.expand("~/.osa/skills/#{name}")
    File.mkdir_p!(skill_dir)

    tools_yaml =
      case tools do
        [] -> ""
        list -> "tools:\n" <> Enum.map_join(list, "\n", fn t -> "  - #{t}" end) <> "\n"
      end

    triggers_yaml = "triggers:\n" <> Enum.map_join(triggers, "\n", fn t -> "  - #{t}" end) <> "\n"

    content = """
    ---
    name: #{name}
    description: #{description}
    #{tools_yaml}#{triggers_yaml}---

    #{instructions}
    """

    skill_path = Path.join(skill_dir, "SKILL.md")
    File.write!(skill_path, content)
    Logger.info("[SkillBootstrap] Wrote #{skill_path}")
    {:ok, skill_path}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp reload_registry do
    OptimalSystemAgent.Tools.Registry.reload_skills()
    :ok
  rescue
    _ -> :ok
  end

  defp start_session(opts) do
    create_opts = Keyword.merge([channel: :http, user_id: "skill_bootstrap"], opts)
    Session.create(create_opts)
  end

  # Send the trigger message as a fire-and-forget task.
  defp dispatch_skill(session_id, message) do
    Task.Supervisor.start_child(
      OptimalSystemAgent.TaskSupervisor,
      fn -> OptimalSystemAgent.Agent.Loop.process_message(session_id, message) end,
      restart: :temporary
    )
  end

  # Build a trigger message that will match at least one of the skill's triggers.
  defp build_trigger_message(name, triggers, description) do
    keyword = List.first(triggers, name)
    "#{keyword}: #{description}"
  end
end
