# ADR-005: Local-First Architecture

## Status

Accepted

## Date

2025-01-01

---

## Context

Most AI agent systems in 2024–2025 are cloud-first by design: they require API keys
from cloud LLM providers, store conversation data on remote servers, and cannot
function without internet access. This architecture raises several problems:

**Privacy**: Every user message, tool output, and agent response is transmitted to
and logged by a third-party provider. For personal assistants handling email, files,
code, and financial data, this is a significant privacy concern.

**Cost**: Cloud LLM APIs charge per token. High-volume agent use — scheduled tasks,
proactive monitoring, background learning — is economically prohibitive for individual
users at cloud prices.

**Availability**: A cloud-only agent fails when the user's internet connection is
unavailable, when the provider has an outage, or when the provider changes its API.

**Data sovereignty**: Users have no guarantee about how their data is stored, used
for training, or shared with third parties by cloud providers.

**Vendor lock-in**: An agent that requires a specific cloud provider cannot be moved
to a different provider without significant disruption.

The question was whether to build Daemon as a cloud-first system (simpler, smaller
codebase, relies on provider infrastructure) or local-first (more complex, requires
local model support, provides privacy and offline capability by default).

---

## Considered Alternatives

### Alternative A: Cloud-First

Daemon requires one or more cloud API keys. Local models are not supported.
Data is stored in a cloud database managed by MIOSA.

**Pros:**
- Significantly simpler architecture — no local inference, no Ollama integration
- Cloud LLM quality is higher than local models at equivalent cost
- No GPU/hardware requirements for users
- MIOSA can offer a hosted SaaS product with per-user accounts

**Cons:**
- All user data transmitted to cloud providers by default
- Breaks completely without internet or when providers are down
- Monthly per-token costs are prohibitive for always-on agents
- Undermines the core Daemon value proposition (a personal OS-level agent)
- Competitor to Claude.ai, ChatGPT — difficult to differentiate

### Alternative B: Local-Only

Daemon requires local model inference (Ollama). Cloud providers are not supported.

**Pros:**
- Maximum privacy — no data ever leaves the machine by default
- Zero per-token cost after hardware
- Fully offline-capable

**Cons:**
- Excludes users without powerful hardware (GPU or Apple Silicon)
- Local model quality is lower for complex reasoning tasks
- Limits adoption — most users do not have Ollama installed

### Alternative C: Local-First with Cloud Fallback (chosen)

Daemon defaults to local inference (Ollama) and runs fully offline when Ollama is
available. Cloud providers are supported as opt-in configuration and as fallback
when local models are unavailable or insufficient for a task.

**Pros:**
- Privacy by default — cloud providers require explicit API key configuration
- Works offline when Ollama is available
- Scales up to cloud quality when user chooses to configure cloud providers
- Three-tier model system (Elite/Specialist/Utility) maps to both local and cloud
- No data ever transmitted to cloud without user explicitly providing an API key

**Cons:**
- Requires Ollama for the offline case; users without Ollama must configure cloud
- More complex provider routing logic (fallback chains, circuit breakers)
- Must test and maintain integrations for 18 providers simultaneously

---

## Decision

Daemon is local-first: Ollama is the default provider (`default_provider: :ollama`).
Cloud providers are supported but require explicit API key configuration. No user
data is transmitted to any external service without the user providing credentials.

### Privacy Implications

**What never leaves the machine by default:**
- All conversation history (stored in SQLite and JSONL in `~/.daemon/`)
- Vault facts (stored in `~/.daemon/vault/`)
- Memory summaries (stored in `~/.daemon/memory/`)
- Tool outputs (shell, file, git operations)
- System information accessed by sidecar tools

**What leaves the machine when cloud providers are configured:**
- Messages sent to the LLM (conversation context, tool results, system prompt)
- Signal classification requests (when LLM-based classification is enabled)

Users who configure cloud provider API keys explicitly accept that their data is
transmitted to those providers. Daemon documents this in the setup wizard and in the
provider configuration documentation.

### Implementation Consequences

The local-first decision drove several architectural choices:

**Ollama boot probe**: At startup, `Providers.Registry` probes Ollama reachability.
If Ollama is unreachable and no cloud providers are configured, the system starts in
a degraded state with a clear warning rather than failing to start.

**18-provider support with 3 tiers**: The tier system maps Elite/Specialist/Utility
to models at each provider, including local Ollama models detected by size. This
allows the same tier routing logic to work across all providers without modification.

**SQLite over cloud database**: All persistent storage uses SQLite (via Ecto/SQLite3).
No external database is required for single-user local operation. PostgreSQL is
supported via opt-in `DATABASE_URL` for multi-tenant platform deployments.

**`~/.daemon/` as the user data directory**: All user data, configuration, skills, and
memory is stored in `~/.daemon/`. This directory belongs to the user and is not
synchronized to any cloud service by Daemon.

**Signal classification fallback**: The deterministic signal classifier requires
no LLM — it is always available offline. LLM-enriched classification is async
and optional.

---

## Consequences

### Benefits

- Users can run a fully capable AI agent on their own hardware with zero cloud costs
- Privacy by default reduces friction for sensitive use cases (personal finance, code,
  health information, communications)
- No dependency on provider availability for core functionality
- Competitive differentiation: Daemon is one of few agent systems that runs fully local
- Decouples Daemon's value proposition from provider pricing changes

### Costs and Trade-offs

- Local model quality is lower than frontier models for complex reasoning tasks;
  users who need best-in-class quality must configure cloud providers
- Ollama must be installed and configured separately; it is not bundled with Daemon
- Testing requires either Ollama or mock providers — no cloud API is universally available
  in CI
- Supporting 18 providers and local Ollama increases maintenance surface

### Compliance Requirements

- The `default_provider` must default to `:ollama`, not a cloud provider
- No user data may be transmitted to any external service without user-provided credentials
- Setup wizard (`mix daemon.setup`) must clearly explain what data leaves the machine
  when a cloud provider is configured
- The `Providers.Registry.chat/2` implementation must handle `{:error, :econnrefused}`
  gracefully (Ollama not running) and route to the fallback chain
