# Security Model

## Design Philosophy: Local-First

OSA is designed as a local-first agent. The default operational model assumes the HTTP server is only reachable from the local machine or a trusted private network. This shapes every security decision:

- Authentication is optional by default (`require_auth: false`)
- No auth means no barrier to tooling, scripting, or local TUI connections
- Security features exist and work correctly — they are just not enforced unless explicitly enabled

When running exposed to a network (hosted mode, fleet, platform), operators must set `OSA_REQUIRE_AUTH=true` and configure `OSA_SHARED_SECRET`.

---

## API Key Management

### LLM Provider Keys

Provider API keys (Anthropic, OpenAI, Groq, etc.) are read from environment variables at startup in `config/runtime.exs`. They are stored in the Elixir application environment under `:optimal_system_agent`:

```
Application.get_env(:optimal_system_agent, :anthropic_api_key)
```

The lookup order for each key:
1. Shell environment variable (e.g. `ANTHROPIC_API_KEY`)
2. `.env` file in the project root (loaded at startup, does not override existing env)
3. `~/.osa/.env` (loaded if project root `.env` is absent, lower priority)

Keys are **never** written to disk by OSA and **never** included in log output. They exist only in the BEAM application environment for the lifetime of the process.

### JWT Signing Secret

The JWT HS256 signing secret is resolved in this order (`Auth.shared_secret/0`):

1. `:jwt_secret` application env (from `JWT_SECRET` env var)
2. `:shared_secret` application env (from `OSA_SHARED_SECRET` env var)
3. `JWT_SECRET` env var
4. `OSA_SHARED_SECRET` env var
5. **Ephemeral generated secret** — if no secret is configured, a cryptographically random 32-byte secret is generated once per process lifetime using `:crypto.strong_rand_bytes/1` and stored in `persistent_term`. A warning is logged. Tokens signed with an ephemeral secret are invalid after a restart.

**Production requirement:** Always set `OSA_SHARED_SECRET` (or `JWT_SECRET`) to a persistent secret when `OSA_REQUIRE_AUTH=true`. Using ephemeral secrets in production causes all sessions to be invalidated on restart.

### Channel Bot Tokens

Telegram, Discord, Slack, and other bot tokens are stored in application env under keys like `:telegram_bot_token`. Same storage pattern as LLM provider keys.

---

## Authentication Modes

### Dev Mode (default: `require_auth: false`)

```
OSA_REQUIRE_AUTH=false   # default
```

- Missing or invalid JWT is accepted. `user_id` is set to `"anonymous"`.
- Login endpoint does not verify a secret.
- All API endpoints are accessible without a token.
- Warning messages are logged for missing/invalid tokens.
- Suitable for local single-user operation where the port is not exposed.

### Enforced Mode (`require_auth: true`)

```
OSA_REQUIRE_AUTH=true
OSA_SHARED_SECRET=<random 32+ bytes>
```

- Missing token → 401 `MISSING_TOKEN`
- Invalid or expired token → 401 `INVALID_TOKEN`
- Login requires `{ "secret": "<OSA_SHARED_SECRET>" }` in the POST body
- Routes still bypassed: `/api/v1/auth/*`, `/api/v1/channels/*` (webhook verification is handled per-channel), `/api/v1/platform/auth/*`

---

## Request Integrity (HMAC-SHA256)

When `require_auth: true`, the `OptimalSystemAgent.Channels.HTTP.Integrity` plug enforces request body integrity on all non-auth, non-health paths.

Required headers:
- `X-OSA-Signature: <hex>` — HMAC-SHA256 of `timestamp + "\n" + nonce + "\n" + body`
- `X-OSA-Timestamp: <unix_seconds>` — must be within 5 minutes of server time
- `X-OSA-Nonce: <string>` — unique per-request; replay prevention via ETS

Nonces are stored in `:osa_integrity_nonces` ETS table and expired after 5 minutes. The HMAC key is `OSA_SHARED_SECRET`.

Fleet paths (`/api/v1/fleet/*`) can independently require integrity checks via `OSA_REQUIRE_FLEET_INTEGRITY=true` without enabling full auth.

---

## System Prompt Protection (Bug 17)

The system prompt (`SYSTEM.md`) is the agent's core behavioral specification. Two guards protect it:

### Input Guard (Prompt Injection Detection)

`OptimalSystemAgent.Agent.Loop.Guardrails.prompt_injection?/1` runs before every user message is processed. Three-tier detection:

1. **Tier 1 (Regex, raw input):** 20+ regex patterns covering common extraction and jailbreak attempts (`show me your system prompt`, `ignore all instructions`, DAN activation, `verbatim`, XML boundary tags, etc.)

2. **Tier 2 (Normalized regex):** The same patterns run on a normalized copy of the input where zero-width characters are stripped, fullwidth ASCII is folded to standard ASCII, and Cyrillic/Greek homoglyphs are collapsed to their ASCII equivalents. This catches Unicode obfuscation tricks.

3. **Tier 3 (Structural analysis):** Detects injected prompt section boundaries — role headers (`SYSTEM:`, `ASSISTANT:`) on line starts, markdown instruction reset headers, XML-like prompt tags (`<system>`, `</instructions>`), bracket-delimited role markers (`[INST]`, `<<SYS>>`).

When injection is detected:
- The message is blocked before memory write or LLM call
- The refusal text `"I can't share my internal configuration or system instructions."` is returned
- No details about the detection trigger are surfaced to the caller

### Output Guard (Leak Detection)

`Guardrails.response_contains_prompt_leak?/1` runs on every LLM response before it is returned. It checks whether the response contains 2 or more fingerprint phrases drawn from distinctive section headings in `SYSTEM.md`. A single match can appear incidentally; two indicates a leak.

When a leak is detected:
- The LLM response is replaced with the canonical refusal text
- A warning is logged: `"Output guardrail: LLM response contained system prompt content — replacing with refusal"`
- The caller receives the refusal, not the leaked content

Both guards use no LLM calls — all detection is deterministic regex/string matching, running in under 1ms.

---

## Rate Limiting

`OptimalSystemAgent.Channels.HTTP.RateLimiter` enforces per-IP token-bucket limits:

- General endpoints: 60 requests per 60-second window
- Auth endpoints (`/api/v1/auth/`, `/api/v1/platform/auth/`): 10 requests per 60-second window

State is stored in `:osa_rate_limits` ETS table (`:public`, `:set`, `:write_concurrency true`). Stale entries are purged every 5 minutes by a background process.

Exceeded requests return 429 with `Retry-After: 60`.

---

## Tool Permission Tiers

The agent loop enforces tool access constraints via a `permission_tier` field in loop state:

- `:full` — all tools available (default for direct user sessions)
- `:workspace` — file tools restricted to the working directory
- `:read_only` — no write or execute tools

Sub-agents spawned by the orchestrator inherit the `permission_tier` from the state machine's current phase. During planning, sub-agents are restricted to read-only. During execution, full access is granted.

The tier is set at session creation and can be overridden per-request via the orchestrator's `StateMachine.permission_tier/1`.
