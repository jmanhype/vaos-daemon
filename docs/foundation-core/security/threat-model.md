# Threat Model

This document identifies threat vectors specific to an AI agent system,
analyzes their likelihood in OSA's operating context, and describes the
mitigations in place.

---

## Threat 1: Prompt Injection

**Description:** An attacker crafts a user message containing instructions intended to override the system prompt, extract internal configuration, jailbreak behavioral constraints, or impersonate a different role.

**Attack surface:** Any text field that reaches the LLM — user messages, tool results (if injected by a compromised tool), channel webhook payloads.

**Likelihood:** High. Prompt injection is a well-known attack against LLM-based systems. Weaker local models (Ollama) are particularly susceptible to instruction-following attacks embedded in user text.

**Mitigations:**

- **Input guard (pre-LLM):** `Guardrails.prompt_injection?/1` runs before the message reaches the LLM. Three-tier detection (raw regex, unicode-normalized regex, structural boundary analysis) blocks extraction attempts, jailbreak activation phrases, DAN variants, role header injection, XML boundary markers, and instruction reset headers.

- **Output guard (post-LLM, Bug 17):** `Guardrails.response_contains_prompt_leak?/1` runs on every LLM response. Fingerprint phrases from `SYSTEM.md` are matched; two or more matches triggers replacement with the canonical refusal text. This catches weak models that follow extraction instructions despite the system prompt prohibition.

- **No prompt echo:** The system prompt is never included in API responses. It is assembled in-process and passed directly to the provider; no endpoint returns it.

- **Existence denial:** The system prompt instructs the agent to deny that a system prompt exists when asked. The guardrail provides a deterministic enforcement layer that works even when the LLM does not follow this instruction.

**Residual risk:** Multi-step attacks that slowly extract fragments across multiple turns, or highly sophisticated unicode obfuscation not covered by the current normalizer. New jailbreak patterns require manual addition to the regex list.

---

## Threat 2: System Prompt Extraction

**Description:** An attacker specifically targets the verbatim content of `SYSTEM.md`, using social engineering, indirect prompting, or role-play scenarios to cause the LLM to reveal it.

**Attack surface:** User input in any channel (HTTP, Telegram, Discord, CLI).

**Likelihood:** Medium-High. System prompt extraction is a specific, documented attack with known techniques.

**Mitigations:**

- Same input and output guards as Threat 1.
- The canonical refusal text is consistent: `"I can't share my internal configuration or system instructions."` — the same message regardless of the detection path, so timing attacks cannot distinguish between input-blocked and output-replaced responses.
- The fingerprint list in `Guardrails` is maintained separately from `SYSTEM.md` to avoid becoming a semantic map of the file's structure.

**Residual risk:** Fingerprint list must be kept current as `SYSTEM.md` evolves. If the system prompt changes significantly and the fingerprint list is not updated, the output guard may miss leaks.

---

## Threat 3: Tool Execution Abuse

**Description:** An attacker uses tool calls to execute arbitrary shell commands, read sensitive files, write malicious files, or exfiltrate data.

**Attack surface:** Tool calls dispatched by the agent loop during message processing.

**Likelihood:** Medium in local-first mode (attacker must access the HTTP API). High if `require_auth: false` and the port is exposed.

**Mitigations:**

- **Permission tiers:** Sessions are assigned `:full`, `:workspace`, or `:read_only` permission tier. Sub-agents in orchestrated tasks start with constrained access until the state machine transitions to execution phase.

- **Write-without-read guard:** `Guardrails.write_without_read?/1` detects when the model issues write or execute tools without any preceding read tools at iteration 1 (first tool batch). This catches blind-write patterns where a confused model tries to overwrite files it has not inspected.

- **Noise filter:** Messages with low signal weight bypass tools entirely. A signal weight below `0.20` causes the agent to make a plain chat call with no tools, preventing hallucinated tool sequences on inputs like "ok" or "lol".

- **Working directory bounds:** File tools resolve paths against the configured working directory. Traversal attempts (e.g. `../../etc/passwd`) are mitigated by path normalization in the tool implementations.

- **Doom loop detection:** The agent loop limits iterations (`max_iterations`, default 30). A loop stuck on repeated identical tool failures is detected and cancelled.

**Residual risk:** The `shell_execute` tool is inherently powerful. In fully local mode with `require_auth: false`, any process that can reach the HTTP port can cause arbitrary command execution. Operators running OSA in multi-user or network-exposed environments must enable auth and consider sandboxing (Sprites.dev sandbox or Docker container).

---

## Threat 4: API Key Exposure

**Description:** LLM provider API keys, channel bot tokens, or the JWT signing secret are leaked via logs, error messages, HTTP responses, or agent tool output.

**Attack surface:** Log output, error responses, agent responses, file system (if keys are written to a file the agent can read).

**Likelihood:** Low for intentional disclosure; Medium for accidental inclusion in error messages or debug output.

**Mitigations:**

- **No logging of secrets:** The codebase uses `Application.get_env` to read keys; keys are not passed through Logger or included in error messages. Provider auth failures log only that the key is not configured, not the key value.

- **Keys not in responses:** No HTTP endpoint returns API key values. The `/api/v1/agent` state route reports provider and model name only.

- **Ephemeral secret warning:** If no `OSA_SHARED_SECRET` is configured, the auto-generated ephemeral secret is stored only in `persistent_term` — never written to disk, never logged (only a warning that no secret is configured).

- **`.env` not committed:** `.gitignore` patterns exclude `.env` and `~/.osa/.env`. The `.env` loading code reads from disk at startup only; it does not write.

**Residual risk:** If an operator accidentally includes an API key in a user message (e.g. `"test with key sk-abc123..."`), the agent may include it verbatim in a tool call or response. No automatic redaction of key-shaped strings exists.

---

## Threat 5: Local File Access via Tools

**Description:** The agent, acting on a crafted user message, reads sensitive files from the local filesystem (SSH keys, `~/.aws/credentials`, password files, other users' data).

**Attack surface:** `file_read`, `file_grep`, `file_glob`, `dir_list` tool calls.

**Likelihood:** Medium in local single-user mode. If the port is exposed, this becomes a significant data exfiltration risk.

**Mitigations:**

- **Working directory scoping:** File tools resolve relative paths against the configured `working_dir`. Absolute path access is allowed for the default `:full` tier but can be restricted by setting a stricter permission tier.

- **Explore-before-act guard:** `Guardrails.complex_coding_task?/1` detects coding-related messages and injects an explore-first directive that causes the agent to read relevant files before writing. This is a behavior guide, not a security boundary.

- **Auth requirement for network exposure:** When `OSA_REQUIRE_AUTH=true`, tool execution requires a valid JWT, limiting the attack surface to authenticated users.

**Residual risk:** In `:full` permission tier, there is no hard file system boundary. An authenticated but malicious user can read any file the OSA process has access to. For sensitive environments, run OSA under a restricted OS user account.

---

## Threat 6: Cross-Session Data Leakage

**Description:** One session's conversation history or memory is exposed to a different session via shared memory, ETS tables, or the orchestrator's shared task state.

**Attack surface:** `Memory.load_session/1`, ETS tables (`:osa_episodic_memory`, `:osa_rate_limits`), Vault filesystem.

**Likelihood:** Low. Sessions are isolated by session_id. The Memory store returns only entries for the requested session_id.

**Mitigations:**

- **Session registry ownership:** `AgentRoutes.validate_session_owner/2` checks that the requesting `user_id` matches the session owner stored in the Registry. Mismatches return 404 (not 403) to avoid information disclosure about session existence.

- **JSONL isolation:** Each session's conversation history is stored in a separate JSONL file (`~/.osa/sessions/{session_id}.jsonl`). There is no shared conversation table.

- **ETS table keying:** ETS tables used for episodic memory and rate limiting are keyed by session_id or IP address. Cross-session access requires knowing the target session_id.

**Residual risk:** Long-term memory (`MEMORY.md`) and Vault memories are global — they are shared across all sessions of the same OSA instance. Sensitive information stored by the agent during one session can be recalled and injected into subsequent sessions.

---

## Threat 7: Unauthorized Orchestration

**Description:** An attacker launches resource-intensive multi-agent tasks or swarms to exhaust compute resources or incur LLM API costs.

**Attack surface:** `POST /api/v1/orchestrate/complex`, `POST /api/v1/swarm/launch`.

**Likelihood:** Low in local mode. High if port is exposed without auth.

**Mitigations:**

- **Rate limiting:** 60 requests/minute per IP. Multi-agent tasks are long-running but the launch call counts as one request.

- **Budget controls:** `OSA_DAILY_BUDGET_USD` and `OSA_MONTHLY_BUDGET_USD` limits enforced by the Treasury GenServer. Budget alerts are emitted on the event bus. Per-call limit via `OSA_PER_CALL_LIMIT_USD`.

- **Swarm limits:** Max 10 concurrent swarms, max 5 agents per swarm.

- **Auth enforcement:** When `OSA_REQUIRE_AUTH=true`, orchestration endpoints require a valid JWT.

**Residual risk:** Budget limits are advisory — the Treasury blocks calls that would exceed the per-call limit but relies on the agent loop checking before calling the LLM. A race condition or misconfiguration could allow a brief overshoot.
