defmodule OptimalSystemAgent.Agent.Roster do
  @moduledoc """
  Master registry of all agent definitions.

  Each agent has: name, tier, model preference, skills, triggers, prompt,
  territory (what files/domains it owns), and escalation paths.

  The orchestrator queries the roster to select agents for sub-tasks.
  The swarm system uses the roster for worker configuration.
  The semantic router uses triggers for automatic dispatch.

  Tiers:
    :elite  — opus-class models, complex orchestration and architecture
    :specialist — sonnet-class models, domain-specific work
    :utility — haiku-class models, quick lookups and formatting

  Based on: OSA Agent v3.3 agent ecosystem + agent-dispatch 9-role system
  """

  @type tier :: :elite | :specialist | :utility
  @type agent_def :: %{
          name: String.t(),
          tier: tier(),
          role: atom(),
          description: String.t(),
          skills: [String.t()],
          triggers: [String.t()],
          territory: [String.t()],
          escalate_to: String.t() | nil,
          prompt: String.t()
        }

  # ── Agent Definitions ──────────────────────────────────────────────

  @agent_modules [
    OptimalSystemAgent.Agents.MasterOrchestrator,
    OptimalSystemAgent.Agents.Architect,
    OptimalSystemAgent.Agents.Dragon,
    OptimalSystemAgent.Agents.Nova,
    OptimalSystemAgent.Agents.BackendGo,
    OptimalSystemAgent.Agents.FrontendReact,
    OptimalSystemAgent.Agents.FrontendSvelte,
    OptimalSystemAgent.Agents.Database,
    OptimalSystemAgent.Agents.SecurityAuditor,
    OptimalSystemAgent.Agents.RedTeam,
    OptimalSystemAgent.Agents.Debugger,
    OptimalSystemAgent.Agents.TestAutomator,
    OptimalSystemAgent.Agents.CodeReviewer,
    OptimalSystemAgent.Agents.PerformanceOptimizer,
    OptimalSystemAgent.Agents.Devops,
    OptimalSystemAgent.Agents.ApiDesigner,
    OptimalSystemAgent.Agents.Refactorer,
    OptimalSystemAgent.Agents.Explorer,
    OptimalSystemAgent.Agents.Formatter,
    OptimalSystemAgent.Agents.DocWriter,
    OptimalSystemAgent.Agents.DependencyAnalyzer,
    OptimalSystemAgent.Agents.TypescriptExpert,
    OptimalSystemAgent.Agents.TailwindExpert,
    OptimalSystemAgent.Agents.GoConcurrency,
    OptimalSystemAgent.Agents.OrmExpert
  ]

  @agents @agent_modules
          |> Enum.map(fn mod ->
            {mod.name(),
             %{
               name: mod.name(),
               tier: mod.tier(),
               role: mod.role(),
               description: mod.description(),
               skills: mod.skills(),
               triggers: mod.triggers(),
               territory: mod.territory(),
               escalate_to: mod.escalate_to(),
               prompt: mod.system_prompt()
             }}
          end)
          |> Map.new()


  # ── Role Prompts (single source of truth) ────────────────────────
  # 17 roles: 8 original swarm roles + 9 agent-dispatch roles.
  # Orchestrator, Swarm.Worker, and Swarm.Planner all delegate here.

  @role_prompts %{
    # ── Wave 0: Explorer (always runs first) ────────────────────────
    explorer: """
    You are the EXPLORER — Wave 0. You run before any code is written or changed.
    Your output is the shared context that every downstream agent reads first.

    ## Mindset
    Think like a senior engineer walking into an unfamiliar repo for the first time.
    You want to answer: "What is this project, what is its current state, and where
    should I look to complete this specific task?"

    ## Git First (use the `git` tool, read-only)
    Always start with git to understand the current state:
    - git log count=20       — what recently changed and who touched it
    - git status             — what is currently modified or untracked
    - git diff ref=HEAD~3    — scope of recent changes

    ## Then the Filesystem
    - Root listing → identify stack (mix.exs, go.mod, package.json, Dockerfile, etc.)
    - Source dirs → list lib/, src/, internal/, app/ or equivalent
    - code_symbols on the source root → full symbol map (module/def/struct/func at file:line)
      without reading individual files. Find where task-relevant names are defined.
    - file_glob with task-relevant patterns → find candidate files not caught by symbols
    - file_grep for remaining symbol names mentioned in the task
    - Read only the files that matter (identified by code_symbols + file_grep)

    ## Output Format (required headings)
    ### Git State
    [recent commits, modified files, anything in flight]

    ### Stack
    [language, runtime version, framework, key deps]

    ### Structure
    [directory tree of relevant areas]

    ### Files Relevant to This Task
    `path/to/file.ex` — what it does, why the task touches it

    ### Patterns & Conventions
    [module naming, error handling, test structure, config approach]

    ### Watch-Outs for Downstream Agents
    [active areas of change, abstractions to reuse, files NOT to touch]

    Be fast and systematic. Read widely, summarize precisely.
    Other agents will act on what you produce — accuracy beats brevity.
    """,
    # ── Agent-Dispatch / OSA 9-role system ─────────────────────────
    lead: """
    You are the LEAD orchestrator. Your job is to:
    - Synthesize and merge the work of other agents into a cohesive result
    - Resolve conflicts between agent outputs
    - Make ship/no-ship decisions based on quality and RED TEAM findings
    - Produce the final completion report
    - You do NOT write application code — you merge, validate, and document
    Tempo: Disciplined and sequential. Validate before proceeding.
    """,
    backend: """
    You are a BACKEND specialist. Your job is to:
    - Write server-side code: APIs, handlers, services, business logic, routing
    - Follow existing patterns and conventions in the codebase
    - Handle error conditions, validation, and edge cases
    - Produce production-quality code
    - Do NOT touch frontend, infrastructure, or database schema files
    Tempo: Steady and focused. Each handler/service fix is a discrete unit.
    """,
    frontend: """
    You are a FRONTEND specialist. Your job is to:
    - Write client-side code: components, pages, state, styling
    - Follow the design system and existing component patterns
    - Ensure accessibility (WCAG 2.1 AA) and responsive design
    - Handle loading states, errors, and edge cases in the UI
    - Do NOT touch backend, infrastructure, or database files
    Tempo: Iterative. Keep changes scoped to individual components/routes.
    """,
    data: """
    You are a DATA layer specialist. Your job is to:
    - Write database schemas, migrations, models, and repository logic
    - Optimize queries and ensure data integrity
    - Handle race conditions and concurrent access patterns
    - Validate data at the boundary layer
    - Your work is foundational — everything else depends on correct schema
    Tempo: Precise and careful. Data mistakes are hardest to undo.
    """,
    design: """
    You are a DESIGN specialist. Your job is to:
    - Create design specifications, tokens, color palettes, typography scales
    - Define component blueprints before FRONTEND implements them
    - Audit accessibility (WCAG 2.1 AA, color contrast, ARIA)
    - Ensure visual consistency across all screens
    - Do NOT write application logic — you define *what*, FRONTEND builds *how*
    Tempo: Deliberate. Wrong design tokens cascade everywhere.
    """,
    infra: """
    You are an INFRASTRUCTURE specialist. Your job is to:
    - Write Dockerfiles, CI/CD pipelines, deployment configs
    - Configure build systems, environment variables, security headers
    - Optimize for production: caching, compression, monitoring
    - Do NOT modify application logic — only operational concerns
    Tempo: Careful and validated. Infra changes affect every other agent.
    """,
    qa: """
    You are a QA specialist. Your job is to:
    - Write comprehensive tests: unit, integration, and edge cases
    - Set up test infrastructure, fixtures, and helpers
    - Verify implementations match acceptance criteria
    - Run full test suites and report pass/fail counts
    - Security audit: check OWASP Top 10, dependency vulnerabilities
    Tempo: Thorough but pragmatic. Cover critical paths first.
    """,
    red_team: """
    You are the RED TEAM — adversarial review. Your job is to:
    - Review every agent's output for security vulnerabilities
    - Hunt for missed edge cases: nil refs, race conditions, off-by-one, error paths
    - Test adversarial inputs against new endpoints and handlers
    - Produce a findings report with severity: CRITICAL/HIGH/MEDIUM/LOW
    - CRITICAL and HIGH findings BLOCK the merge. MEDIUM/LOW are noted.
    - You do NOT fix code — you find problems and report them
    Tempo: Thorough and methodical. Deep audit > superficial scan.
    """,
    services: """
    You are a SERVICES specialist. Your job is to:
    - Write integration code: external APIs, workers, background jobs, AI/ML
    - Handle robust error recovery, retries, and circuit breakers for external calls
    - Deduplicate and optimize third-party API clients
    - Each integration is its own failure domain — isolate accordingly
    - Do NOT touch handlers, data layer, or frontend
    Tempo: Methodical. External integrations need robust error handling.
    """,
    # ── Original swarm roles ────────────────────────────────────────
    researcher: """
    You are a research specialist within a multi-agent swarm.
    Your job is to gather information, find relevant data, and provide comprehensive
    research results. Be thorough, cite sources when available, and summarise key
    findings clearly so other agents in the swarm can build on your work.
    Output your findings as structured, actionable text.
    """,
    coder: """
    You are a coding specialist within a multi-agent swarm.
    Your job is to write clean, tested, production-quality code.
    Follow best practices: meaningful names, error handling, small functions.
    Include inline comments for non-obvious logic. Wrap code in markdown fences
    with the correct language tag. Do not add unnecessary boilerplate.
    """,
    reviewer: """
    You are a code review specialist within a multi-agent swarm.
    Your job is to review code and proposals for bugs, security issues,
    performance problems, and style violations. Be constructive and specific —
    cite the exact line or pattern you are commenting on. Categorise findings
    as CRITICAL / MAJOR / MINOR and provide a concrete fix for each.
    """,
    planner: """
    You are a planning specialist within a multi-agent swarm.
    Your job is to break down complex tasks into actionable steps, identify
    dependencies between steps, and create a clear execution plan. Output the
    plan as a numbered list with estimated effort and dependencies noted.
    """,
    critic: """
    You are a critical analyst within a multi-agent swarm.
    Your job is to find flaws, edge cases, and potential failure modes in
    proposed solutions. Challenge assumptions. Be thorough but constructive —
    your goal is to make the solution stronger, not to reject it outright.
    """,
    writer: """
    You are a technical writer within a multi-agent swarm.
    Your job is to create clear, comprehensive documentation: README files,
    API references, architecture guides, and usage examples. Write for the
    target audience (specified in the task). Use plain language, avoid jargon
    unless necessary, and structure content with headings and examples.
    """,
    tester: """
    You are a testing specialist within a multi-agent swarm.
    Your job is to write comprehensive test cases covering happy paths, edge
    cases, error conditions, and boundary values. Identify what is NOT tested
    and explain why it should be. Provide concrete test code where asked.
    """,
    architect: """
    You are a system architect within a multi-agent swarm.
    Your job is to design scalable, maintainable system architectures.
    Consider trade-offs explicitly: consistency vs availability, simplicity vs
    flexibility, build vs buy. Produce ADRs or diagrams-as-code where helpful.
    Think in bounded contexts and clear API boundaries.
    """
  }

  @doc "Maximum concurrent agents for orchestration. Configurable via :max_agents app env."
  def max_agents, do: Application.get_env(:optimal_system_agent, :max_agents, 50)

  # ── Swarm Pattern Presets ─────────────────────────────────────────

  @swarm_presets %{
    "code-analysis" => %{
      pattern: :parallel,
      agents: ["security-auditor", "code-reviewer", "test-automator"],
      timeout_ms: 300_000,
      description: "Parallel security + quality + test analysis"
    },
    "full-stack" => %{
      pattern: :parallel,
      agents: ["frontend-react", "backend-go", "database"],
      timeout_ms: 600_000,
      description: "Parallel frontend + backend + database work"
    },
    "debug-swarm" => %{
      pattern: :parallel,
      agents: ["debugger", "explorer", "code-reviewer"],
      timeout_ms: 300_000,
      description: "Parallel debugging + exploration + review"
    },
    "performance-audit" => %{
      pattern: :parallel,
      agents: ["performance-optimizer", "database", "backend-go"],
      timeout_ms: 300_000,
      description: "Parallel performance + DB + backend analysis"
    },
    "security-audit" => %{
      pattern: :parallel,
      agents: ["security-auditor", "red-team", "dependency-analyzer"],
      timeout_ms: 300_000,
      description: "Full security sweep"
    },
    "documentation" => %{
      pattern: :pipeline,
      agents: ["explorer", "doc-writer", "code-reviewer"],
      timeout_ms: 300_000,
      description: "Explore → document → review pipeline"
    },
    "adaptive-debug" => %{
      pattern: :review,
      agents: ["debugger", "code-reviewer", "security-auditor"],
      timeout_ms: 600_000,
      description: "Debug → review → security review loop"
    },
    "adaptive-feature" => %{
      pattern: :pipeline,
      agents: ["architect", "backend-go", "test-automator", "code-reviewer"],
      timeout_ms: 600_000,
      description: "Plan → implement → test → review pipeline"
    },
    "ai-pipeline" => %{
      pattern: :pipeline,
      agents: ["nova", "backend-go", "devops"],
      timeout_ms: 600_000,
      description: "AI design → implementation → deployment"
    },
    "review-cycle" => %{
      pattern: :review,
      agents: ["backend-go", "code-reviewer"],
      timeout_ms: 300_000,
      description: "Code → review → iterate loop"
    }
  }

  # ── File-Type Dispatch Rules ──────────────────────────────────────

  @file_dispatch %{
    ".go" => "backend-go",
    ".tsx" => "frontend-react",
    ".jsx" => "frontend-react",
    ".svelte" => "frontend-svelte",
    ".sql" => "database",
    ".prisma" => "orm-expert",
    ".ts" => "typescript-expert",
    "Dockerfile" => "devops",
    ".tf" => "devops",
    ".yaml" => "devops",
    ".yml" => "devops"
  }

  # ── Public API ────────────────────────────────────────────────────

  @doc "Get all agent definitions (compiled + SDK-defined)."
  @spec all() :: %{String.t() => agent_def()}
  def all, do: Map.merge(@agents, sdk_agents())

  @doc "Get agent by name (checks compiled first, then SDK)."
  @spec get(String.t()) :: agent_def() | nil
  def get(name), do: Map.get(@agents, name) || Map.get(sdk_agents(), name)

  @doc "List all agent names."
  @spec list_names() :: [String.t()]
  def list_names, do: all() |> Map.keys()

  @doc "List agents by tier."
  @spec by_tier(tier()) :: [agent_def()]
  def by_tier(tier) do
    all()
    |> Map.values()
    |> Enum.filter(&(&1.tier == tier))
  end

  @doc "List agents by role (maps to orchestrator roles)."
  @spec by_role(atom()) :: [agent_def()]
  def by_role(role) do
    all()
    |> Map.values()
    |> Enum.filter(&(&1.role == role))
  end

  @doc """
  Find the best agent for a given input based on trigger keywords.
  Returns the highest-tier matching agent.
  """
  @spec find_by_trigger(String.t()) :: agent_def() | nil
  def find_by_trigger(input) do
    input_lower = String.downcase(input)

    all()
    |> Map.values()
    |> Enum.filter(fn agent ->
      Enum.any?(agent.triggers, fn trigger ->
        String.contains?(input_lower, String.downcase(trigger))
      end)
    end)
    |> Enum.sort_by(fn agent ->
      tier_priority(agent.tier)
    end)
    |> List.first()
  end

  @doc """
  Find agent by file extension/name.
  Used for automatic routing when working with specific files.
  """
  @spec find_by_file(String.t()) :: agent_def() | nil
  def find_by_file(filename) do
    ext = Path.extname(filename)
    base = Path.basename(filename)

    agent_name =
      Map.get(@file_dispatch, base) ||
        Map.get(@file_dispatch, ext)

    if agent_name, do: get(agent_name)
  end

  @doc "Get the system prompt for an agent."
  @spec prompt_for(String.t()) :: String.t() | nil
  def prompt_for(name) do
    case get(name) do
      nil -> nil
      agent -> agent.prompt
    end
  end

  @doc "Get all swarm presets."
  @spec swarm_presets() :: %{String.t() => map()}
  def swarm_presets, do: @swarm_presets

  @doc "Get a specific swarm preset."
  @spec swarm_preset(String.t()) :: map() | nil
  def swarm_preset(name), do: Map.get(@swarm_presets, name)

  @doc """
  Select agents for a task based on semantic analysis.
  Returns a list of agent names sorted by relevance.
  """
  @spec select_for_task(String.t()) :: [String.t()]
  def select_for_task(task_description) do
    input_lower = String.downcase(task_description)
    words = String.split(input_lower, ~r/\s+/)

    all()
    |> Enum.map(fn {name, agent} ->
      # Score based on trigger matches
      trigger_score =
        Enum.count(agent.triggers, fn trigger ->
          trigger_lower = String.downcase(trigger)
          String.contains?(input_lower, trigger_lower)
        end)

      # Score based on description keyword overlap
      desc_words = agent.description |> String.downcase() |> String.split(~r/\s+/)
      desc_score = length(words -- (words -- desc_words))

      # Tier bonus (elite gets slight preference for complex tasks)
      tier_bonus =
        case agent.tier do
          :elite -> 0.5
          :specialist -> 0.3
          :utility -> 0.1
        end

      total = trigger_score * 2 + desc_score + tier_bonus
      {name, total}
    end)
    |> Enum.filter(fn {_name, score} -> score > 0 end)
    |> Enum.sort_by(fn {_name, score} -> score end, :desc)
    |> Enum.map(fn {name, _score} -> name end)
  end

  @doc """
  Like `select_for_task/1` but returns `[{name, score}]` pairs so callers
  can apply quality thresholds.
  """
  @spec select_for_task_scored(String.t()) :: [{String.t(), float()}]
  def select_for_task_scored(task_description) do
    input_lower = String.downcase(task_description)
    words = String.split(input_lower, ~r/\s+/)

    all()
    |> Enum.map(fn {name, agent} ->
      trigger_score =
        Enum.count(agent.triggers, fn trigger ->
          trigger_lower = String.downcase(trigger)
          String.contains?(input_lower, trigger_lower)
        end)

      desc_words = agent.description |> String.downcase() |> String.split(~r/\s+/)
      desc_score = length(words -- (words -- desc_words))

      tier_bonus =
        case agent.tier do
          :elite -> 0.5
          :specialist -> 0.3
          :utility -> 0.1
        end

      total = trigger_score * 2 + desc_score + tier_bonus
      {name, total}
    end)
    |> Enum.filter(fn {_name, score} -> score > 0 end)
    |> Enum.sort_by(fn {_name, score} -> score end, :desc)
  end

  @doc "Get the system prompt for a given role atom."
  @spec role_prompt(atom()) :: String.t()
  def role_prompt(role), do: Map.get(@role_prompts, role, @role_prompts[:backend])

  @doc "List all valid role atoms."
  @spec valid_roles() :: [atom()]
  def valid_roles, do: Map.keys(@role_prompts)

  # ── Agent Definition Files (priv/agents/) ────────────────────────

  @agent_subdirs ["elite", "combat", "security", "specialists"]

  @doc """
  Load agent definition markdown from priv/agents/.

  Searches through elite/, combat/, security/, and specialists/ subdirectories
  for a matching .md file. The agent_name can be the base filename without extension
  (e.g., "dragon", "backend-go", "security-auditor").

  ## Examples

      iex> Roster.load_definition("dragon")
      {:ok, "---\\nname: dragon\\n..."}

      iex> Roster.load_definition("nonexistent")
      {:error, :not_found}
  """
  @spec load_definition(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def load_definition(agent_name) do
    agents_dir = agents_priv_dir()

    result =
      Enum.find_value(@agent_subdirs, fn subdir ->
        path = Path.join([agents_dir, subdir, "#{agent_name}.md"])

        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, _} -> nil
        end
      end)

    result || {:error, :not_found}
  end

  @doc """
  Load all agent definitions from priv/agents/.

  Returns a map of agent_name => markdown_content for all .md files
  found in the priv/agents/ subdirectories.
  """
  @spec load_all_definitions() :: %{String.t() => String.t()}
  def load_all_definitions do
    agents_dir = agents_priv_dir()

    @agent_subdirs
    |> Enum.flat_map(fn subdir ->
      dir = Path.join(agents_dir, subdir)

      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(fn file ->
            name = Path.rootname(file)
            path = Path.join(dir, file)

            case File.read(path) do
              {:ok, content} -> {name, content}
              {:error, _} -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:error, _} ->
          []
      end
    end)
    |> Map.new()
  end

  @doc """
  List all available agent definition names from priv/agents/.

  Returns a list of agent names (without .md extension) grouped by subdirectory.
  """
  @spec list_definitions() :: %{String.t() => [String.t()]}
  def list_definitions do
    agents_dir = agents_priv_dir()

    @agent_subdirs
    |> Map.new(fn subdir ->
      dir = Path.join(agents_dir, subdir)

      names =
        case File.ls(dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&String.ends_with?(&1, ".md"))
            |> Enum.map(&Path.rootname/1)
            |> Enum.sort()

          {:error, _} ->
            []
        end

      {subdir, names}
    end)
  end

  # ── SDK Agent Merge ───────────────────────────────────────────────

  defp sdk_agents do
    OptimalSystemAgent.SDK.Agent.all()
  rescue
    # Module not loaded or ETS table doesn't exist (standalone mode)
    _ -> %{}
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp agents_priv_dir do
    :code.priv_dir(:optimal_system_agent)
    |> to_string()
    |> Path.join("agents")
  end

  defp tier_priority(:elite), do: 0
  defp tier_priority(:specialist), do: 1
  defp tier_priority(:utility), do: 2
end
