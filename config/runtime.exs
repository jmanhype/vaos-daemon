import Config

# ── Helper functions for env var parsing ─────────────────────────────────
parse_float = fn
  nil, default ->
    default

  str, default ->
    case Float.parse(str) do
      {val, _} -> val
      :error -> default
    end
end

parse_int = fn
  nil, default ->
    default

  str, default ->
    case Integer.parse(str) do
      {val, _} -> val
      :error -> default
    end
end

# ── .env file loading ──────────────────────────────────────────────────
# Load .env from project root OR ~/.osa/.env (project root takes priority).
# Only sets vars that aren't already in the environment (explicit env wins).
# Skipped in test env so DAEMON_HTTP_PORT / DATABASE_URL from .env don't
# override test.exs config (port 0, platform_enabled: false).
if config_env() != :test do
  for env_path <- [Path.expand(".env"), Path.expand("~/.osa/.env")] do
    if File.exists?(env_path) do
      env_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(fn line ->
        line = String.trim(line)

        case line do
          "#" <> _ ->
            :skip

          "" ->
            :skip

          _ ->
            case String.split(line, "=", parts: 2) do
              [key, value] ->
                key = String.trim(key)
                value = value |> String.trim() |> String.trim("\"") |> String.trim("'")

                if key != "" and value != "" and is_nil(System.get_env(key)) do
                  System.put_env(key, value)
                end

              _ ->
                :skip
            end
        end
      end)
    end
  end
end

# Smart provider auto-detection: explicit override > API key presence > ollama fallback
provider_map = %{
  "ollama" => :ollama, "anthropic" => :anthropic, "openai" => :openai,
  "groq" => :groq, "openrouter" => :openrouter, "together" => :together,
  "fireworks" => :fireworks, "deepseek" => :deepseek, "mistral" => :mistral,
  "cerebras" => :cerebras, "google" => :google, "cohere" => :cohere,
  "perplexity" => :perplexity, "xai" => :xai, "sambanova" => :sambanova,
  "hyperbolic" => :hyperbolic, "lmstudio" => :lmstudio, "llamacpp" => :llamacpp,
  "zhipu" => :zhipu, "qwen" => :qwen, "moonshot" => :moonshot,
  "baichuan" => :baichuan, "volcengine" => :volcengine
}

default_provider =
  cond do
    env = System.get_env("DAEMON_DEFAULT_PROVIDER") -> Map.get(provider_map, env, :ollama)
    System.get_env("ANTHROPIC_API_KEY") -> :anthropic
    System.get_env("OPENAI_API_KEY") -> :openai
    System.get_env("GROQ_API_KEY") -> :groq
    System.get_env("OPENROUTER_API_KEY") -> :openrouter
    System.get_env("ZHIPU_API_KEY") -> :zhipu
    true -> :ollama
  end

config :daemon,
  # LLM Providers — API keys
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  anthropic_url: System.get_env("ANTHROPIC_BASE_URL") || "https://api.anthropic.com/v1",
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  groq_api_key: System.get_env("GROQ_API_KEY"),
  openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),
  google_api_key: System.get_env("GOOGLE_API_KEY"),
  deepseek_api_key: System.get_env("DEEPSEEK_API_KEY"),
  mistral_api_key: System.get_env("MISTRAL_API_KEY"),
  together_api_key: System.get_env("TOGETHER_API_KEY"),
  fireworks_api_key: System.get_env("FIREWORKS_API_KEY"),
  replicate_api_key: System.get_env("REPLICATE_API_KEY"),
  perplexity_api_key: System.get_env("PERPLEXITY_API_KEY"),
  cohere_api_key: System.get_env("COHERE_API_KEY"),
  qwen_api_key: System.get_env("QWEN_API_KEY"),
  zhipu_api_key: System.get_env("ZHIPU_API_KEY"),
  moonshot_api_key: System.get_env("MOONSHOT_API_KEY"),
  volcengine_api_key: System.get_env("VOLCENGINE_API_KEY"),
  baichuan_api_key: System.get_env("BAICHUAN_API_KEY"),
  xai_api_key: System.get_env("XAI_API_KEY"),
  cerebras_api_key: System.get_env("CEREBRAS_API_KEY"),
  sambanova_api_key: System.get_env("SAMBANOVA_API_KEY"),
  hyperbolic_api_key: System.get_env("HYPERBOLIC_API_KEY"),
  lmstudio_api_key: System.get_env("LMSTUDIO_API_KEY"),
  llamacpp_api_key: System.get_env("LLAMACPP_API_KEY"),

  # LLM Providers — model overrides (per-provider, takes precedence over DAEMON_MODEL)
  google_model: System.get_env("GOOGLE_MODEL"),
  deepseek_model: System.get_env("DEEPSEEK_MODEL"),
  mistral_model: System.get_env("MISTRAL_MODEL"),
  together_model: System.get_env("TOGETHER_MODEL"),
  fireworks_model: System.get_env("FIREWORKS_MODEL"),
  replicate_model: System.get_env("REPLICATE_MODEL"),
  perplexity_model: System.get_env("PERPLEXITY_MODEL"),
  cohere_model: System.get_env("COHERE_MODEL"),
  qwen_model: System.get_env("QWEN_MODEL"),
  zhipu_model: System.get_env("ZHIPU_MODEL"),
  moonshot_model: System.get_env("MOONSHOT_MODEL"),
  volcengine_model: System.get_env("VOLCENGINE_MODEL"),
  baichuan_model: System.get_env("BAICHUAN_MODEL"),
  xai_model: System.get_env("XAI_MODEL"),
  cerebras_model: System.get_env("CEREBRAS_MODEL"),
  sambanova_model: System.get_env("SAMBANOVA_MODEL"),
  hyperbolic_model: System.get_env("HYPERBOLIC_MODEL"),
  lmstudio_model: System.get_env("LMSTUDIO_MODEL"),
  llamacpp_model: System.get_env("LLAMACPP_MODEL"),

  # Ollama overrides (OLLAMA_API_KEY required for cloud instances)
  ollama_url: System.get_env("OLLAMA_URL") || "http://localhost:11434",
  ollama_model: System.get_env("OLLAMA_MODEL") || "qwen2.5:7b",
  ollama_api_key: System.get_env("OLLAMA_API_KEY"),
  # OLLAMA_THINK: set to "true" to enable extended reasoning (kimi-k2, qwen3-thinking, etc.)
  # Default nil → ollama.ex disables thinking for known reasoning models to prevent timeouts.
  ollama_think: (case System.get_env("OLLAMA_THINK") do
    "true" -> true
    "false" -> false
    _ -> nil
  end),

  # Channel tokens
  telegram_bot_token: System.get_env("TELEGRAM_BOT_TOKEN"),
  telegram_webhook_secret: System.get_env("TELEGRAM_WEBHOOK_SECRET"),
  discord_bot_token: System.get_env("DISCORD_BOT_TOKEN"),
  slack_bot_token: System.get_env("SLACK_BOT_TOKEN"),
  # Web search
  brave_api_key: System.get_env("BRAVE_API_KEY"),
  # Academic paper search (Semantic Scholar)
  semantic_scholar_api_key: System.get_env("SEMANTIC_SCHOLAR_API_KEY"),

  # Provider selection
  default_provider: default_provider,
  # Default model — resolved from DAEMON_MODEL env, or provider-specific env var.
  # Falls back to OLLAMA_MODEL only when the active provider is actually ollama.
  default_model: (
    System.get_env("DAEMON_MODEL") ||
      case default_provider do
        :ollama -> System.get_env("OLLAMA_MODEL") || "qwen2.5:7b"
        :groq -> System.get_env("GROQ_MODEL")
        :anthropic -> System.get_env("ANTHROPIC_MODEL")
        :openai -> System.get_env("OPENAI_MODEL")
        :openrouter -> System.get_env("OPENROUTER_MODEL")
        :deepseek -> System.get_env("DEEPSEEK_MODEL")
        :together -> System.get_env("TOGETHER_MODEL")
        :fireworks -> System.get_env("FIREWORKS_MODEL")
        :mistral -> System.get_env("MISTRAL_MODEL")
        :google -> System.get_env("GOOGLE_MODEL")
        :cohere -> System.get_env("COHERE_MODEL")
        :xai -> System.get_env("XAI_MODEL")
        :cerebras -> System.get_env("CEREBRAS_MODEL")
        :lmstudio -> System.get_env("LMSTUDIO_MODEL")
        :llamacpp -> System.get_env("LLAMACPP_MODEL")
        _ -> nil
      end
  ),

  # HTTP channel
  shared_secret:
    System.get_env("DAEMON_SHARED_SECRET") ||
      (if System.get_env("DAEMON_REQUIRE_AUTH") == "true" do
         raise "DAEMON_SHARED_SECRET must be set when DAEMON_REQUIRE_AUTH=true"
       else
         # Don't override test.exs or config.exs secrets; nil means dev mode (open access)
         Application.get_env(:daemon, :shared_secret)
       end),
  require_auth: System.get_env("DAEMON_REQUIRE_AUTH", "false") == "true",

  # Budget limits (USD)
  daily_budget_usd: parse_float.(System.get_env("DAEMON_DAILY_BUDGET_USD"), 50.0),
  monthly_budget_usd: parse_float.(System.get_env("DAEMON_MONTHLY_BUDGET_USD"), 500.0),
  per_call_limit_usd: parse_float.(System.get_env("DAEMON_PER_CALL_LIMIT_USD"), 5.0),

  # Treasury — keys match Treasury GenServer expectations
  treasury_enabled: System.get_env("DAEMON_TREASURY_ENABLED") == "true",
  computer_use_enabled: System.get_env("DAEMON_COMPUTER_USE_ENABLED") == "true",
  treasury_auto_debit: System.get_env("DAEMON_TREASURY_AUTO_DEBIT") != "false",
  treasury_daily_limit: parse_float.(System.get_env("DAEMON_TREASURY_DAILY_LIMIT"), 250.0),
  treasury_max_single: parse_float.(System.get_env("DAEMON_TREASURY_MAX_SINGLE"), 50.0),

  # Fleet management
  fleet_enabled: System.get_env("DAEMON_FLEET_ENABLED") == "true",

  # Heartbeat interval (ms) — how often the scheduler checks HEARTBEAT.md
  # Default: 300_000 (5 min). Set HEARTBEAT_INTERVAL_MS to override.
  heartbeat_interval: String.to_integer(System.get_env("HEARTBEAT_INTERVAL_MS") || "300000"),

  # Wallet integration
  wallet_enabled: System.get_env("DAEMON_WALLET_ENABLED") == "true",
  wallet_provider: System.get_env("DAEMON_WALLET_PROVIDER") || "mock",
  wallet_address: System.get_env("DAEMON_WALLET_ADDRESS"),
  wallet_rpc_url: System.get_env("DAEMON_WALLET_RPC_URL"),

  # Sprites.dev sandbox
  sprites_token: System.get_env("SPRITES_TOKEN"),
  sprites_api_url: System.get_env("SPRITES_API_URL") || "https://api.sprites.dev",

  # OTA updates
  update_enabled: System.get_env("DAEMON_UPDATE_ENABLED") == "true",
  update_url: System.get_env("DAEMON_UPDATE_URL"),
  update_interval: parse_int.(System.get_env("DAEMON_UPDATE_INTERVAL"), 86_400_000),

  # Provider failover chain — auto-detected from configured API keys.
  # Override with comma-separated list: DAEMON_FALLBACK_CHAIN=anthropic,openai,ollama
  fallback_chain: (
    case System.get_env("DAEMON_FALLBACK_CHAIN") do
      nil ->
        candidates = [
          {:anthropic, System.get_env("ANTHROPIC_API_KEY")},
          {:openai, System.get_env("OPENAI_API_KEY")},
          {:groq, System.get_env("GROQ_API_KEY")},
          {:openrouter, System.get_env("OPENROUTER_API_KEY")},
          {:deepseek, System.get_env("DEEPSEEK_API_KEY")},
          {:together, System.get_env("TOGETHER_API_KEY")},
          {:fireworks, System.get_env("FIREWORKS_API_KEY")},
          {:mistral, System.get_env("MISTRAL_API_KEY")},
          {:google, System.get_env("GOOGLE_API_KEY")},
          {:cohere, System.get_env("COHERE_API_KEY")}
        ]

        configured = for {name, key} <- candidates, key != nil and key != "", do: name

        # Only add Ollama if it's actually reachable (TCP check, 1s timeout).
        # Prevents Req.TransportError{reason: :econnrefused} on every provider failure.
        ollama_url = System.get_env("OLLAMA_URL") || "http://localhost:11434"
        ollama_uri = URI.parse(ollama_url)
        ollama_host = String.to_charlist(ollama_uri.host || "localhost")
        ollama_port = ollama_uri.port || 11434

        # If OLLAMA_API_KEY is set, assume Ollama Cloud is reachable (skip TCP check).
        # Otherwise, TCP-check local Ollama.
        ollama_reachable =
          if System.get_env("OLLAMA_API_KEY") do
            true
          else
            case :gen_tcp.connect(ollama_host, ollama_port, [], 1_000) do
              {:ok, sock} -> :gen_tcp.close(sock); true
              {:error, _} -> false
            end
          end

        chain = if ollama_reachable do
          (configured ++ [:ollama]) |> Enum.uniq()
        else
          configured
        end

        Enum.reject(chain, &(&1 == default_provider))

      csv ->
        csv
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(fn name ->
          try do
            String.to_existing_atom(name)
          rescue
            ArgumentError -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
    end
  ),

  # Plan mode (opt-in via DAEMON_PLAN_MODE=true)
  plan_mode_enabled: System.get_env("DAEMON_PLAN_MODE") == "true",

  # Extended thinking
  thinking_enabled: System.get_env("DAEMON_THINKING_ENABLED") == "true",
  thinking_budget_tokens: parse_int.(System.get_env("DAEMON_THINKING_BUDGET"), 5_000),

  # Quiet hours for heartbeat
  quiet_hours: System.get_env("DAEMON_QUIET_HOURS"),

  # Default working directory for the agent (e.g. a project you want OSA to work on).
  # Set DAEMON_WORKING_DIR=~/Desktop/BOS to point OSA at the BOS codebase by default.
  working_dir: (case System.get_env("DAEMON_WORKING_DIR") do
    nil -> nil
    path -> Path.expand(path)
  end)

# ── WorkDirector Configuration ────────────────────────────────────────
# Set DAEMON_WD_ENABLED=false to disable WorkDirector's autonomous dispatch loop.
# Useful for experiments where you only want run_experiment_task/3 direct invocation.
wd_autonomous = System.get_env("DAEMON_WD_ENABLED") != "false"
config :daemon, wd_autonomous_enabled: wd_autonomous

# Set DAEMON_WD_PROFILE=full to enable all flags, =minimal to disable all.
# Individual flags: DAEMON_WD_VAULT_CONTEXT=true, DAEMON_WD_TEST_GATE=true, etc.
wd_profile = System.get_env("DAEMON_WD_PROFILE")
wd_flag = fn env_var ->
  case wd_profile do
    "full" -> true
    "minimal" -> false
    _ -> System.get_env(env_var) == "true"
  end
end

config :daemon,
  wd_enable_vault_context: wd_flag.("DAEMON_WD_VAULT_CONTEXT"),
  wd_enable_knowledge_context: wd_flag.("DAEMON_WD_KNOWLEDGE_CONTEXT"),
  wd_enable_investigation_pre: wd_flag.("DAEMON_WD_INVESTIGATION_PRE"),
  wd_enable_appraiser: wd_flag.("DAEMON_WD_APPRAISER"),
  wd_enable_specialist_routing: wd_flag.("DAEMON_WD_SPECIALIST_ROUTING"),
  wd_enable_swarm_dispatch: wd_flag.("DAEMON_WD_SWARM_DISPATCH"),
  wd_enable_substance_check: wd_flag.("DAEMON_WD_SUBSTANCE_CHECK"),
  wd_enable_autofixer: wd_flag.("DAEMON_WD_AUTOFIXER"),
  wd_enable_test_gate: wd_flag.("DAEMON_WD_TEST_GATE"),
  wd_enable_code_review: wd_flag.("DAEMON_WD_CODE_REVIEW"),
  wd_enable_review_fix_loop: wd_flag.("DAEMON_WD_REVIEW_FIX_LOOP"),
  wd_enable_vault_remember: wd_flag.("DAEMON_WD_VAULT_REMEMBER"),
  wd_enable_knowledge_remember: wd_flag.("DAEMON_WD_KNOWLEDGE_REMEMBER"),
  wd_enable_skill_evolution: wd_flag.("DAEMON_WD_SKILL_EVOLUTION"),
  wd_enable_introspector_feed: wd_flag.("DAEMON_WD_INTROSPECTOR_FEED"),
  wd_enable_risk_assessment: wd_flag.("DAEMON_WD_RISK_ASSESSMENT"),
  wd_enable_risk_approval_gate: wd_flag.("DAEMON_WD_RISK_APPROVAL_GATE"),
  wd_enable_strategic_rejection: wd_flag.("DAEMON_WD_STRATEGIC_REJECTION"),
  wd_enable_strategic_debate: wd_flag.("DAEMON_WD_STRATEGIC_DEBATE"),
  wd_enable_impact_analysis: wd_flag.("DAEMON_WD_IMPACT_ANALYSIS"),
  wd_enable_production_context: wd_flag.("DAEMON_WD_PRODUCTION_CONTEXT"),
  wd_enable_already_solved_check: wd_flag.("DAEMON_WD_ALREADY_SOLVED_CHECK"),
  wd_enable_pr_conflict_awareness: wd_flag.("DAEMON_WD_PR_CONFLICT_AWARENESS"),
  wd_enable_dispatch_confidence: wd_flag.("DAEMON_WD_DISPATCH_CONFIDENCE"),
  wd_enable_task_decomposition: wd_flag.("DAEMON_WD_TASK_DECOMPOSITION")

# ── Platform (multi-tenant PostgreSQL + AMQP) ────────────────────────
# These are optional — OSA works standalone without them.
# Set DATABASE_URL to enable Platform.Repo (PostgreSQL for users, tenants, OS instances).
# Set AMQP_URL to enable event publishing to Go workers.
# Set JWT_SECRET to share JWT signing key with the Go backend.

database_url = System.get_env("DATABASE_URL")

if database_url do
  config :daemon, Daemon.Platform.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  config :daemon, ecto_repos: [Daemon.Store.Repo, Daemon.Platform.Repo]
end

config :daemon,
  jwt_secret: System.get_env("JWT_SECRET"),
  amqp_url: System.get_env("AMQP_URL"),
  platform_enabled: database_url != nil

# ── Production (Film Studio Chrome Automation) ────────────────────────
# Set DAEMON_PRODUCTION_ENABLED=true to start the Chrome automation subsystem:
# ChromeSlot (1 concurrent Chrome user), FlowRateLimiter (submission cooldowns),
# ChromeHealth (periodic Chrome/OSA.app health checks).
config :daemon,
  production_enabled: System.get_env("DAEMON_PRODUCTION_ENABLED") == "true"

config :daemon, receipt_chain_enabled: System.get_env("RECEIPT_CHAIN_ENABLED") == "true"

# ── VAOS Kernel gRPC ─────────────────────────────────────────────────
# URL for the Go vaos-kernel gRPC service (JWT tokens, telemetry, audit, routing).
# Format: grpc://host:port — defaults to localhost:50051 if set to "true" or empty.
vas_kernel_url =
  case System.get_env("VAOS_KERNEL_URL") do
    nil -> nil
    "true" -> "grpc://localhost:50051"
    "" -> nil
    url -> url
  end

config :daemon, vas_kernel_url: vas_kernel_url
