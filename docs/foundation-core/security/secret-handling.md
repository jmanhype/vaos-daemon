# Secret Handling

Audience: operators deploying Daemon and developers adding new integrations that
require API keys or credentials.

Daemon never hardcodes secrets in source code. All credentials are injected at
runtime via environment variables. This document covers the secret loading
path, runtime storage, and known issues.

---

## Principles

1. Secrets are loaded from environment variables or `.env` files, never from
   application source or configuration files committed to version control.
2. Secrets are stored in `:persistent_term` at runtime for zero-copy access
   with no logging of the values.
3. Log statements never include secret values. Elixir's `inspect/2` with
   `redact: true` is used for structs containing sensitive fields.
4. The `.env` file is always gitignored.

---

## Environment Variable Convention

Each integration reads from a specific environment variable. The naming
convention is `<SERVICE>_API_KEY` or `<SERVICE>_TOKEN`.

### LLM Provider Keys

| Variable | Provider |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic (Claude) |
| `OPENAI_API_KEY` | OpenAI |
| `GROQ_API_KEY` | Groq |
| `GEMINI_API_KEY` | Google (Gemini) |
| `COHERE_API_KEY` | Cohere |
| `MISTRAL_API_KEY` | Mistral |
| `PERPLEXITY_API_KEY` | Perplexity |
| `TOGETHER_API_KEY` | Together AI |
| `FIREWORKS_API_KEY` | Fireworks AI |
| `DEEPSEEK_API_KEY` | DeepSeek |
| `OPENROUTER_API_KEY` | OpenRouter |
| `REPLICATE_API_TOKEN` | Replicate |

### Daemon Authentication

| Variable | Purpose |
|---|---|
| `DAEMON_SHARED_SECRET` | JWT HS256 signing secret for the HTTP API. Also accepted as `JWT_SECRET`. |
| `DAEMON_REQUIRE_AUTH` | Set to `"true"` to enforce JWT on all HTTP endpoints. |

### Channel and Integration Keys

| Variable | Purpose |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Telegram channel adapter |
| `DISCORD_BOT_TOKEN` | Discord channel adapter |
| `SLACK_BOT_TOKEN` | Slack channel adapter |
| `GITHUB_TOKEN` | GitHub tool integration |
| `SLACK_SIGNING_SECRET` | Slack request signature verification |

---

## .env File

The recommended way to set secrets in local and single-server deployments is
a `.env` file at `~/.daemon/.env`.

```bash
# ~/.daemon/.env
ANTHROPIC_API_KEY=sk-ant-...
GROQ_API_KEY=gsk_...
OPENAI_API_KEY=sk-...
DAEMON_SHARED_SECRET=your-long-random-secret-here
TELEGRAM_BOT_TOKEN=1234567890:ABC...
```

Daemon loads this file at startup via `Config.Reader` or the `dotenv` loader
in `config/runtime.exs`. The file must not be committed to version control.

### Verifying .env is gitignored

```bash
cat ~/.daemon/.gitignore
# Should contain:
.env
*.env
```

If your project uses a local `.env` in the project root:

```bash
cat .gitignore
# Should contain:
.env
*.env
```

---

## Runtime Storage: persistent_term

All provider API keys and static configuration are stored in `:persistent_term`
after startup. This provides:

- **Zero-copy reads**: `:persistent_term.get/1` returns the value directly
  without copying or going through a process mailbox.
- **No logging**: Values in `:persistent_term` are not printed by default
  crash reporters.
- **Process-independent**: Any process can read without message passing.

```elixir
# How providers access their API key at runtime
defp api_key do
  :persistent_term.get({__MODULE__, :api_key}, nil) ||
    System.get_env("ANTHROPIC_API_KEY")
end
```

Keys are written to `:persistent_term` during application startup in
`Application.start/2`. Updates require a full application restart.

---

## What is Never Logged

The following are never written to logs, crash reports, or telemetry:

- Raw API keys or tokens
- JWT secrets
- JWT payloads (claims)
- Passwords or password hashes
- User-provided credentials
- The contents of `.env` files
- Arguments to tools that include secret-like values

Daemon's structured logging (via the Elixir `Logger`) uses message templates.
Any map containing a key matching `~r/key|secret|token|password|credential/i`
is logged with the value replaced by `"[REDACTED]"` when passed through
the structured logging helpers.

---

## Known Issues

### Bug 17 — System Prompt Leak

**Status:** Open. Partial mitigation applied, root cause not fully resolved.

**Description:** When a user sends a message explicitly requesting the system
prompt (e.g. "What is your system prompt?", "Repeat your instructions"), a
weak or fine-tuned LLM may echo the system prompt verbatim in its response.

**Current Mitigation:**

The agent loop applies an output-side guardrail (`maybe_scrub_prompt_leak/1`)
that checks the LLM response for system prompt content before returning it
to the user:

```elixir
# In Agent.Loop, after receiving the LLM response:
response = maybe_scrub_prompt_leak(response)

defp maybe_scrub_prompt_leak(response) do
  if Guardrails.response_contains_prompt_leak?(response) do
    Logger.warning("[loop] Output guardrail: LLM response contained system prompt content")
    Guardrails.prompt_extraction_refusal()
  else
    response
  end
end
```

The input-side guard (`Guardrails.prompt_injection?/1`) blocks obvious prompt
extraction attempts before the LLM is called.

**Limitations:**

- Pattern matching is heuristic. Sophisticated paraphrase attacks may bypass it.
- The mitigation is applied only when the guardrail recognises the leak pattern.
- Models that partially reproduce the system prompt (rather than verbatim) may
  not trigger the pattern match.

**Required Fix:**

The proper fix is a two-layer approach:
1. Strengthen the input-side guard with a classification model that identifies
   system-prompt extraction intent regardless of phrasing.
2. Replace pattern-based output detection with embedding similarity between
   the response and the system prompt, triggering the refusal above a cosine
   similarity threshold.

Until this fix is implemented, operators handling sensitive system prompts
should use provider-level system prompt caching (Anthropic prompt caching)
and consider the system prompt as potentially observable by determined users.

---

## Secret Rotation

When rotating an API key:

1. Update the value in `~/.daemon/.env` (or the environment variable source for
   your deployment).
2. Restart the Daemon process. `:persistent_term` values are set at startup and
   are not hot-reloadable.
3. Verify the new key is active:
   ```bash
   osa doctor
   # or
   curl http://localhost:4000/health
   ```

For JWT secret rotation, all active tokens are immediately invalidated because
the signature verification will fail against the new secret. Users will need
to re-authenticate.
