defmodule OSA.SDK do
  @moduledoc """
  Public facade for the OSA SDK.

  The entry point for external Elixir applications to embed the full OSA
  agent runtime. All functions delegate to internal `Daemon.SDK.*`
  modules.

  ## Quick Start

      # Simple query
      {:ok, messages} = OSA.SDK.query("What is 2+2?")

      # With options
      {:ok, messages} = OSA.SDK.query("Fix the bug in auth.ex", [
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        permission: :accept_edits
      ])

  ## Embedded Mode

  Add to your supervision tree for a standalone OSA runtime:

      config = %Daemon.SDK.Config{
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        permission: :accept_edits,
        http_port: 8090
      }

      children = [
        {Daemon.SDK.Supervisor, config}
      ]

  ## Custom Tools

      OSA.SDK.define_tool(
        "weather",
        "Get weather for a city",
        %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}, "required" => ["city"]},
        fn %{"city" => city} -> {:ok, "72°F in \#{city}"} end
      )

  ## Custom Agents

      OSA.SDK.define_agent("my-reviewer", %{
        tier: :specialist,
        role: :qa,
        description: "Domain-specific code reviewer",
        skills: ["file_read"],
        triggers: ["domain review"],
        territory: ["*.ex"],
        escalate_to: nil,
        prompt: "You are a domain-specific reviewer..."
      })
  """

  # ── Query & Swarm ────────────────────────────────────────────────

  @doc """
  Send a message through the full OSA agent pipeline.

  See `Daemon.SDK.query/2` for full documentation.
  """
  defdelegate query(message, opts \\ []), to: Daemon.SDK

  @doc """
  Launch a multi-agent swarm on a task.

  See `Daemon.SDK.launch_swarm/2` for full documentation.
  """
  defdelegate launch_swarm(task, opts \\ []), to: Daemon.SDK

  @doc """
  Execute an approved plan from a previous query that returned :plan.

  See `Daemon.SDK.execute_plan/3` for full documentation.
  """
  defdelegate execute_plan(session_id, message, opts \\ []), to: Daemon.SDK

  # ── Tool Registration ────────────────────────────────────────────

  @doc """
  Define a custom tool via closure.

  See `Daemon.SDK.Tool.define/4` for full documentation.
  """
  defdelegate define_tool(name, description, parameters, handler),
    to: Daemon.SDK.Tool,
    as: :define

  @doc "Remove a previously defined SDK tool."
  defdelegate undefine_tool(name), to: Daemon.SDK.Tool, as: :undefine

  # ── Agent Registration ───────────────────────────────────────────

  @doc """
  Define a custom agent at runtime.

  See `Daemon.SDK.Agent.define/2` for full documentation.
  """
  defdelegate define_agent(name, definition),
    to: Daemon.SDK.Agent,
    as: :define

  @doc "Remove a previously defined SDK agent."
  defdelegate undefine_agent(name), to: Daemon.SDK.Agent, as: :undefine

  # ── Hook Registration ────────────────────────────────────────────

  @doc """
  Register a hook for an agent lifecycle event.

  See `Daemon.SDK.Hook.register/4` for full documentation.
  """
  defdelegate register_hook(event, name, handler, opts \\ []),
    to: Daemon.SDK.Hook,
    as: :register

  @doc "List all registered hooks."
  defdelegate list_hooks(), to: Daemon.SDK.Hook, as: :list

  @doc "Get hook execution metrics."
  defdelegate hook_metrics(), to: Daemon.SDK.Hook, as: :metrics

  @doc "Run a hook pipeline synchronously."
  defdelegate run_hook(event, payload), to: Daemon.SDK.Hook, as: :run

  @doc "Run a hook pipeline asynchronously (fire-and-forget)."
  defdelegate run_hook_async(event, payload), to: Daemon.SDK.Hook, as: :run_async

  # ── Session Management ───────────────────────────────────────────

  @doc "Create a new agent session."
  defdelegate create_session(opts \\ []), to: Daemon.SDK.Session, as: :create

  @doc "Resume an existing session."
  defdelegate resume_session(session_id, opts \\ []),
    to: Daemon.SDK.Session,
    as: :resume

  @doc "Close a session."
  defdelegate close_session(session_id), to: Daemon.SDK.Session, as: :close

  @doc "List active sessions."
  defdelegate list_sessions(), to: Daemon.SDK.Session, as: :list

  @doc "Get messages for a session."
  defdelegate get_messages(session_id), to: Daemon.SDK.Session, as: :get_messages

  @doc "Check if a session is alive."
  defdelegate session_alive?(session_id), to: Daemon.SDK.Session, as: :alive?

  # ── Memory ───────────────────────────────────────────────────────

  @doc "Recall all persistent memories."
  defdelegate recall(), to: Daemon.SDK.Memory

  @doc "Recall memories relevant to a query within token budget."
  defdelegate recall_relevant(message, max_tokens \\ 2000), to: Daemon.SDK.Memory

  @doc "Save an insight to persistent memory."
  defdelegate remember(content, category \\ "general"), to: Daemon.SDK.Memory

  @doc "Search memories by keyword."
  defdelegate search_memory(query, opts \\ []), to: Daemon.SDK.Memory, as: :search

  @doc "Load a session's message history."
  defdelegate load_session(session_id), to: Daemon.SDK.Memory

  @doc "Get memory statistics."
  defdelegate memory_stats(), to: Daemon.SDK.Memory, as: :stats

  @doc "Append a message entry to a session's persistent history."
  defdelegate append_message(session_id, entry), to: Daemon.SDK.Memory, as: :append

  @doc "Resume a session from persistent history (checks existence)."
  defdelegate resume_memory_session(session_id), to: Daemon.SDK.Memory, as: :resume_session

  @doc "Get per-session stats (token totals, message counts)."
  defdelegate session_stats(session_id), to: Daemon.SDK.Memory

  # ── Budget ───────────────────────────────────────────────────────

  @doc "Check if current spending is within budget limits."
  defdelegate check_budget(), to: Daemon.SDK.Budget, as: :check

  @doc "Get full budget status: limits, spent, remaining, reset times."
  defdelegate budget_status(), to: Daemon.SDK.Budget, as: :status

  @doc "Record an API cost entry."
  defdelegate record_cost(provider, model, tokens_in, tokens_out, session_id),
    to: Daemon.SDK.Budget

  @doc "Calculate USD cost for token counts (pure function)."
  defdelegate calculate_cost(provider, tokens_in, tokens_out),
    to: Daemon.SDK.Budget

  @doc "Set daily budget limit in USD."
  defdelegate set_daily_limit(usd), to: Daemon.SDK.Budget

  @doc "Set monthly budget limit in USD."
  defdelegate set_monthly_limit(usd), to: Daemon.SDK.Budget

  # ── Tiers & Models ──────────────────────────────────────────────

  @doc "Get model name for a tier on a given provider."
  defdelegate model_for(tier, provider), to: Daemon.SDK.Tier

  @doc "Get model for a named agent (tier-based routing)."
  defdelegate model_for_agent(agent_name), to: Daemon.SDK.Tier

  @doc "Get token budget breakdown for a tier."
  defdelegate budget_for(tier), to: Daemon.SDK.Tier

  @doc "Get all tier configurations."
  defdelegate all_tiers(), to: Daemon.SDK.Tier, as: :all

  @doc "List all supported LLM providers."
  defdelegate supported_providers(), to: Daemon.SDK.Tier

  @doc "Map complexity score (1-10) to tier."
  defdelegate tier_for_complexity(complexity), to: Daemon.SDK.Tier

  @doc "Get full tier info (budget, temperature, max_iterations, max_agents)."
  defdelegate tier_info(tier), to: Daemon.SDK.Tier

  @doc "Max response tokens for a tier."
  defdelegate max_response_tokens(tier), to: Daemon.SDK.Tier

  @doc "Temperature setting for a tier."
  defdelegate temperature(tier), to: Daemon.SDK.Tier

  @doc "Max concurrent agents for a tier."
  defdelegate max_agents(tier), to: Daemon.SDK.Tier

  @doc "Max loop iterations for a tier."
  defdelegate max_iterations(tier), to: Daemon.SDK.Tier

  # ── Commands ─────────────────────────────────────────────────────

  @doc "Execute a slash command programmatically."
  defdelegate execute_command(input, session_id \\ "sdk"),
    to: Daemon.SDK.Command,
    as: :execute

  @doc "List all registered commands."
  defdelegate list_commands(), to: Daemon.SDK.Command, as: :list

  @doc "Register a custom slash command at runtime."
  defdelegate register_command(name, description, template), to: Daemon.SDK.Command, as: :register

  # ── MCP ──────────────────────────────────────────────────────────

  @doc "List all configured MCP servers."
  defdelegate list_mcp_servers(), to: Daemon.SDK.MCP, as: :list_servers

  @doc "List all MCP-provided tools registered in Tools.Registry."
  defdelegate list_mcp_tools(), to: Daemon.SDK.MCP, as: :list_tools

  @doc "Reload MCP server configs from disk."
  defdelegate reload_mcp_servers(), to: Daemon.SDK.MCP, as: :reload_servers

  # ── Convenience ──────────────────────────────────────────────────

  @doc "Alias for the Config struct module."
  def config, do: Daemon.SDK.Config

  @doc "Alias for the Message struct module."
  def message, do: Daemon.SDK.Message

  @doc "Alias for the Permission module."
  def permission, do: Daemon.SDK.Permission

  # ── Investigation Pipeline ─────────────────────────────────────────

  @doc """
  Investigate a claim or topic using the epistemic investigation pipeline.

  Runs multi-source paper search (Semantic Scholar + OpenAlex + alphaXiv)
  with FOR, AGAINST, and REVIEWS queries, then performs dual adversarial
  LLM analysis with citation verification and evidence hierarchy scoring.

  ## Options

    * `:depth` - Either `:standard` (adversarial debate + citation verification)
      or `:deep` (standard + research pipeline with hypotheses and testing)
    * `:strategy` - A map with investigation parameters (optional, uses defaults if not provided)

  ## Returns

    * `{:ok, result}` - Map with investigation results including verdict,
      supporting/opposing evidence, quality scores, and metadata
    * `{:error, reason}` - If investigation fails

  ## Example

      {:ok, result} = OSA.SDK.investigate("Does MCTS improve LLM reasoning?")
  """
  defdelegate investigate(topic, opts \\ []), to: Daemon.SDK.Investigation

  @doc """
  Get the current investigation strategy for a topic.

  Returns the strategy parameters that will be used for investigations.
  """
  defdelegate investigation_strategy(topic), to: Daemon.SDK.Investigation, as: :get_strategy

  @doc """
  Update investigation strategy parameters for a topic.

  Allows fine-tuning of investigation behavior including scoring weights,
  thresholds, and search limits.
  """
  defdelegate update_investigation_strategy(topic, params),
    to: Daemon.SDK.Investigation,
    as: :update_strategy

  @doc """
  List all available investigation prompt variants with their stats.

  Returns a list of prompt variants with Thompson Sampling posterior
  statistics (alpha, beta, total_trials).
  """
  defdelegate list_investigation_prompts(), to: Daemon.SDK.Investigation, as: :list_prompts

  @doc """
  Register a new investigation prompt variant.

  Allows adding custom prompt templates for A/B testing via Thompson Sampling.
  """
  defdelegate register_investigation_prompt(prompts, opts \\ []),
    to: Daemon.SDK.Investigation,
    as: :register_prompt

  @doc """
  Get investigation quality metrics and retrospector statistics.

  Returns information about investigation outcomes, experiment status,
  and optimization results.
  """
  defdelegate investigation_metrics(), to: Daemon.SDK.Investigation, as: :metrics

  @doc """
  Score a paper's source quality for investigation evidence classification.

  Returns a float in [0.0, 1.0] indicating source quality based on
  citations, publisher reputation, and publication type.
  """
  defdelegate score_paper_source(paper, strategy \\ nil),
    to: Daemon.SDK.Investigation,
    as: :score_source

  @doc """
  Classify evidence as grounded or belief based on verification and source quality.

  Implements Verification-Aware Classification (VAC) to gate the grounded
  evidence store.
  """
  defdelegate classify_evidence(verification, source_quality, strategy \\ nil),
    to: Daemon.SDK.Investigation,
    as: :classify_evidence
end
