# Integration Points

External systems Daemon connects to. Each section covers the integration mechanism,
configuration keys, and where in the codebase the connection is established.

---

## LLM Providers

### Provider Abstraction

All LLM calls route through `Daemon.Providers.Registry` (a GenServer). Each provider implements `Daemon.Providers.Behaviour`. The registry supports 18 providers:

| Category | Providers |
|---|---|
| Local | ollama |
| OpenAI-compatible | openai, groq, together, fireworks, deepseek, perplexity, mistral, openrouter, qwen, moonshot, zhipu, volcengine, baichuan |
| Native API | anthropic, google, cohere, replicate |

OpenAI-compatible providers all route through `Daemon.Providers.OpenAICompatProvider`, which handles the shared request/response shape. Native API providers (Anthropic, Google, Cohere) have dedicated modules with protocol-specific logic.

### Anthropic

**Module:** `Daemon.Providers.Anthropic`
**API:** `https://api.anthropic.com/v1/messages` (API version `2023-06-01`)
**Auth:** `x-api-key: <ANTHROPIC_API_KEY>` header
**Config key:** `:anthropic_api_key` from `ANTHROPIC_API_KEY` env var

Default model: `claude-sonnet-4-6`. Available models: `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5`.

Features: system message extraction (first system role message becomes Anthropic `system` field), extended thinking (`betas: ["interleaved-thinking-2025-05-14"]`), tool use with `input_schema` format.

### OpenAI and Compatible

**Module:** `Daemon.Providers.OpenAICompatProvider`
**Base URLs by provider:** Groq (`api.groq.com/openai`), Together (`api.together.xyz`), Deepseek (`api.deepseek.com`), etc.
**Auth:** `Authorization: Bearer <API_KEY>` header

Config keys follow the pattern `:<provider>_api_key` from env var `<PROVIDER>_API_KEY` (e.g. `OPENAI_API_KEY`, `GROQ_API_KEY`).

Model overrides via `<PROVIDER>_MODEL` env vars or `:default_model` config key.

### Ollama

**Module:** `Daemon.Providers.Ollama`
**Base URL:** `http://localhost:11434` (override via `OLLAMA_URL`)
**Auth:** optional `OLLAMA_API_KEY` for cloud Ollama instances

Default model: `qwen2.5:7b` (override via `OLLAMA_MODEL`). The registry performs a TCP reachability check (1 second timeout) at startup before including Ollama in the fallback chain.

### Provider Fallback Chain

Auto-detected from configured API keys at runtime startup in `config/runtime.exs`. Order: anthropic → openai → groq → openrouter → deepseek → together → fireworks → mistral → google → cohere → ollama (if reachable).

Override via `DAEMON_FALLBACK_CHAIN=anthropic,openai,ollama` (comma-separated).

The active provider is tried first. On failure, the registry iterates the fallback chain.

---

## Channel Integrations

Daemon connects to messaging platforms via channel adapters. Each adapter implements `Daemon.Channels.Behaviour` and operates as a named GenServer. Adapters start only when their required tokens are configured.

### Telegram

**Module:** `Daemon.Channels.Telegram`
**Mode:** Webhook — Telegram POSTs updates to `POST /api/v1/channels/telegram/webhook`
**Outbound:** REST calls to `https://api.telegram.org/bot<TOKEN>/sendMessage`
**Config:** `TELEGRAM_BOT_TOKEN` env var → `:telegram_bot_token` config key
**Verification:** Webhook URL is registered via `set_webhook/1` call at startup
**Features:** Text messages, MarkdownV2 formatting, inline keyboards

### Discord

**Module:** `Daemon.Channels.Discord`
**Mode:** Webhook interactions — Discord POSTs to `POST /api/v1/channels/discord/webhook`
**Outbound:** `https://discord.com/api/v10/channels/<id>/messages` with `Authorization: Bot <token>`
**Config:** `DISCORD_BOT_TOKEN`, `DISCORD_APPLICATION_ID`, `DISCORD_PUBLIC_KEY`
**Verification:** Ed25519 signature verification on incoming interaction payloads using `DISCORD_PUBLIC_KEY`

### WhatsApp

**Module:** `Daemon.Channels.Whatsapp`
**Mode:** Webhook (WhatsApp Cloud API) and Baileys (local Node.js sidecar at `priv/sidecar/baileys/`)
**Config:** Meta Cloud API token or Baileys local connection

### Slack

**Module:** `Daemon.Channels.Slack` (inferred from config key)
**Config:** `SLACK_BOT_TOKEN` env var → `:slack_bot_token`

### Additional Channels

Signal, Matrix, QQ, DingTalk, and Feishu adapters follow the same pattern. Each has a module under `lib/daemon/channels/` and receives webhooks at `POST /api/v1/channels/<platform>/webhook`.

### Webhook Authentication

Channel webhook routes bypass the JWT authenticate plug (`/api/v1/channels/*` is excluded). Platform-specific verification happens inside each channel's route handler:
- Discord: Ed25519 signature verification via `DISCORD_PUBLIC_KEY`
- Telegram: Token-based verification
- Others: HMAC or challenge-response as required by each platform

---

## Filesystem

### Agent Working Directory

The agent can read and write files on the local filesystem via tools (`file_read`, `file_write`, `file_edit`, `file_grep`, `file_glob`, `dir_list`). The working directory defaults to:
1. `DAEMON_WORKING_DIR` env var if set
2. `working_dir` parameter in the API request
3. Process current working directory

File tools enforce path bounds — relative paths are resolved against the working directory. Shell execution (`shell_execute`) runs in the same directory context.

### Daemon Data Directories

All Daemon-managed data lives under `~/.daemon/` (configurable via `DAEMON_BOOTSTRAP_DIR`):

| Path | Purpose |
|---|---|
| `~/.daemon/sessions/{session_id}.jsonl` | Conversation history (append-only JSONL) |
| `~/.daemon/MEMORY.md` | Long-term memory (markdown, structured with categories) |
| `~/.daemon/vault/{category}/*.md` | Vault structured memories (markdown with YAML frontmatter) |
| `~/.daemon/vault/.vault/checkpoints/` | Session checkpoint snapshots |
| `~/.daemon/vault/handoffs/` | Cross-session handoff packages |
| `~/.daemon/skills/*.md` | SKILL.md skill definitions |
| `~/.daemon/.env` | Environment variable overrides |
| `~/.daemon/mcp.json` | MCP server definitions |

### Git Integration

The orchestrator uses `Daemon.Agent.Orchestrator.GitVersioning` to:
- Checkpoint the working directory state before multi-agent execution
- Commit orchestration outcomes after completion

Git operations are run in detached `Task` processes to prevent blocking the GenServer.

---

## SQLite Database

**Adapter:** `ecto_sqlite3` (Ecto adapter for SQLite3)
**Repo module:** `Daemon.Store.Repo`
**Database path:** `~/.daemon/osa.db` (configurable)

The main SQLite database stores structured data that requires querying or indexing, as opposed to the JSONL files used for raw conversation history.

Tables: `conversations`, `contacts`, `messages`, `task_queue`, `budget_ledger`, `budget_config`, `treasury`, `treasury_transactions`, `sessions_fts` (virtual FTS5 table).

Migrations are in `priv/repo/migrations/`. Run `mix ecto.migrate` to apply.

See `data/data-model.md` for the full schema.

---

## PostgreSQL (Platform — Optional)

**Adapter:** Postgrex
**Repo module:** `Daemon.Platform.Repo`
**Enabled when:** `DATABASE_URL` env var is set

Used for multi-tenant platform data: users, tenants, OS instances, grants, survey responses. Daemon runs standalone without PostgreSQL — all core agent functionality uses SQLite only.

Connection pool size: `POOL_SIZE` env var (default 10).

---

## AMQP / RabbitMQ (Optional)

**Library:** `:amqp`
**Enabled when:** `AMQP_URL` env var is set

Publishes events to Go worker queues for fleet-scale processing. Not required for standalone operation.

---

## MCP Servers

**Config:** `~/.daemon/mcp.json`

Daemon auto-discovers and connects to MCP (Model Context Protocol) servers defined in the config file. MCP tools are registered into `Tools.Registry` at startup with a `mcp_<server>_` prefix on tool names. Tools become available to the LLM immediately after registration.

---

## Web Search (Brave API)

**Module:** `Daemon.Tools.Builtins.WebSearch`
**API:** `https://api.search.brave.com/res/v1/web/search`
**Config:** `BRAVE_API_KEY` env var → `:brave_api_key`
**Availability:** Tool reports `available? = false` if key is not configured

---

## Email (SendGrid)

**Config:** `SENDGRID_API_KEY` env var → `:email_api_key`

Used by the email channel adapter for outbound notifications.

---

## Sprites.dev Sandbox

**Config:** `SPRITES_TOKEN`, `SPRITES_API_URL`
**Purpose:** Isolated execution sandbox for code tool operations in hosted mode

Enabled via `DAEMON_SPRITES_ENABLED`. When configured, code execution tools (`shell_execute`, `code_sandbox`) route to the Sprites API instead of running locally.
