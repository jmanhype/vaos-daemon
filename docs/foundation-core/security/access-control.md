# Access Control

## Current State

Daemon does not implement role-based access control (RBAC) in its local-first mode. Access control is binary: either all API endpoints are open (dev mode) or all require a valid JWT (enforced mode). There is no per-endpoint or per-resource permission model beyond session ownership.

---

## Authentication Modes

### Dev Mode (default)

```
DAEMON_REQUIRE_AUTH=false   # default when env var is absent
```

All API endpoints accept requests without credentials. The `authenticate` plug assigns `user_id: "anonymous"` and `workspace_id: nil`. No authorization checks are performed beyond session ownership on SSE streams (and even that check is bypassed for `"anonymous"` users).

This mode is appropriate for single-user local operation where the HTTP port (default 4000) is bound to `localhost` or protected by OS-level network isolation.

### Enforced Mode

```
DAEMON_REQUIRE_AUTH=true
DAEMON_SHARED_SECRET=<secret>
```

Every request (except the bypassed routes below) must carry a valid `Authorization: Bearer <jwt>` header. The JWT must be:
- Signed with HS256 using the configured `DAEMON_SHARED_SECRET`
- Not expired (`exp` claim in the future)
- Contain a `user_id` claim

Missing or invalid tokens return 401 with a `code` field of `MISSING_TOKEN` or `INVALID_TOKEN`.

---

## Bypassed Routes

These paths explicitly skip JWT authentication regardless of `require_auth` mode:

| Path prefix | Reason |
|---|---|
| `/api/v1/auth/*` | Login endpoint cannot require a token (chicken-and-egg) |
| `/api/v1/channels/*` | Webhook payloads from external platforms use platform-specific auth |
| `/api/v1/platform/auth/*` | Platform login flow uses its own credentials |
| `/health` | Health check must be accessible without auth for monitoring |

Channel webhooks perform their own per-platform verification (Ed25519 for Discord, token matching for Telegram, HMAC for others) inside the route handler.

---

## Session Ownership

When `require_auth: true`, SSE stream connections enforce session ownership:

1. The creating user's `user_id` is stored as the Registry value when the Loop GenServer starts.
2. `AgentRoutes.validate_session_owner/2` compares the requesting `user_id` (from JWT claims) against the stored owner.
3. If the IDs do not match, the response is 404 (not 403) to avoid disclosing that the session exists.
4. `"anonymous"` is always allowed through (for dev-mode compatibility).

Sessions created via `POST /api/v1/sessions` are owned by `conn.assigns[:user_id]`.

Sessions created implicitly by `POST /api/v1/orchestrate` (via `Session.ensure_loop/3`) use `conn.body_params["user_id"]` or fall back to `conn.assigns[:user_id]`.

---

## Platform Multi-Tenant Access Control

When `DATABASE_URL` is configured and `platform_enabled: true`, Daemon activates a multi-tenant layer with its own access control:

**Roles (in `platform_users.role`):**
- `"user"` — default
- `"admin"` — platform-level admin (full access to tenant management)

**Tenant membership (`tenant_members.role`):**
- `"owner"` — full control of the tenant and its OS instances
- `"admin"` — tenant administration (invite members, manage instances)
- `"member"` — standard member

**OS instance access (`os_instance_members`):**
- Per-instance role: `"owner"`, `"admin"`, `"member"`
- Per-instance permissions map (`permissions: map()`) for fine-grained capability control

**Cross-OS grants (`cross_os_grants`):**
- Source OS grants a named capability to a target OS instance
- `grant_type` — the permission being granted (e.g. `"read_memory"`, `"invoke_tool"`)
- `resource_pattern` — glob-style pattern of resources covered
- `expires_at` — optional expiry; revoked via `revoked_at` timestamp

Platform auth uses JWT with `JWT_SECRET`, which can be shared with the Go backend. Platform JWTs contain `user_id` and `workspace_id` claims used by the platform routes.

---

## Request Integrity Controls

When `require_auth: true`, the Integrity plug enforces HMAC-SHA256 body signing:

- Nonce deduplication prevents replay attacks (ETS table, 5-minute window)
- Timestamp window prevents capture-and-replay (5-minute tolerance)
- Signature covers the body content — prevents body tampering in transit

This is optional even in enforced mode; it requires clients to implement signing. The Rust TUI does implement signing. External API clients would need to as well.

Fleet endpoints (`/api/v1/fleet/*`) can independently require integrity checks via `DAEMON_REQUIRE_FLEET_INTEGRITY=true`.

---

## Tool Permission Tiers

Tool access within the agent loop is controlled by a `permission_tier` field on the Loop GenServer state:

| Tier | Allowed tools |
|---|---|
| `:full` | All tools (file read, write, edit, shell execute, etc.) |
| `:workspace` | File tools scoped to the working directory; no absolute paths |
| `:read_only` | Read and query tools only (`file_read`, `file_grep`, `file_glob`, `dir_list`, web search) |

Default: `:full` for user-initiated sessions.

Orchestrator sub-agents inherit the tier from the state machine phase. The `StateMachine.permission_tier/1` function returns the appropriate tier for each phase.

---

## Future RBAC Considerations

The current binary auth model is intentional for local-first use. As Daemon moves toward hosted multi-tenant deployment, the following RBAC dimensions would need to be added:

1. **Per-endpoint permission scopes** — grant clients the ability to call only `GET /sessions` without being able to `POST /orchestrate/complex`
2. **Tool allowlist per user** — restrict which tools a given JWT can invoke
3. **Budget quotas per user** — per-user spending limits rather than instance-wide limits
4. **Audit logging** — structured log of all actions taken per user_id with timestamps

None of these exist today. The Platform multi-tenant schema provides the data model foundation for items 1–3 but the enforcement layer is not implemented.
