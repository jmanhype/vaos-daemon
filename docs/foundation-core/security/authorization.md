# Authorization

Audience: operators configuring multi-tenant deployments and developers
implementing authorization checks in custom channel adapters or tools.

OSA uses role-based access control (RBAC) via `OptimalSystemAgent.Platform.Grants`
and JWT-embedded roles. For single-user local deployments, authorization is
effectively bypassed. For multi-tenant platform deployments, every request is
checked against the grants table.

---

## Role-Based Access Control

### Roles

Three roles are defined. Each role inherits all capabilities of roles below it.

| Role | Capabilities |
|---|---|
| `"admin"` | Full control. Manage users, channels, providers, OS instances, and tenant configuration. |
| `"user"` | Standard agent access. Send messages, invoke tools, create skills, manage own sessions. |
| `"viewer"` | Read-only. Query agent state, session history, and tool listings. Cannot invoke the agent. |

### Role Claim

The role is embedded in the JWT payload at login time:

```json
{
  "user_id": "usr_01jn...",
  "email":   "alice@example.com",
  "role":    "admin"
}
```

The HTTP auth middleware extracts and validates the role claim on every request.
No separate role lookup is performed at request time — the JWT is the source of truth.

### Checking Role in Code

```elixir
# Inside a Plug or route handler
case conn.assigns[:claims] do
  %{"role" => "admin"} ->
    # Permit admin-only action
    proceed(conn)

  %{"role" => "user"} ->
    # Permit standard user action
    proceed(conn)

  _ ->
    conn
    |> put_status(403)
    |> json(%{error: "Forbidden"})
    |> halt()
end
```

---

## Per-Request Authorization

The HTTP channel applies authorization at the plug level before routing:

1. Extract `Authorization: Bearer <token>` from the request header.
2. Verify token via `HTTP.Auth.verify_token/1`.
3. Decode claims and store in `conn.assigns[:claims]`.
4. Route-level checks inspect `claims["role"]` as needed.

Routes that require elevated access check the role explicitly. The `/health`
endpoint and `/auth/*` routes are exempt from authentication.

---

## Grants (Multi-Tenant)

`OptimalSystemAgent.Platform.Grants` manages cross-OS-instance permissions.
This is relevant for fleet deployments where one OS instance needs to invoke
or query another.

### Grant Schema

```elixir
# platform/schemas/grant.ex
%{
  source_os_id: "osi_abc",   # Granting OS instance
  target_os_id: "osi_xyz",   # Receiving OS instance
  grant_type:   "read",      # "read" | "write" | "admin"
  expires_at:   ~U[2026-12-31 00:00:00Z],  # nil = permanent
  revoked_at:   nil
}
```

### Grant Operations

```elixir
alias OptimalSystemAgent.Platform.Grants

# List all active grants for an OS instance
grants = Grants.list("osi_abc")

# Create a grant (source → target)
{:ok, grant} = Grants.create(%{
  source_os_id: "osi_abc",
  target_os_id: "osi_xyz",
  grant_type:   "read",
  expires_at:   DateTime.add(DateTime.utc_now(), 86_400)  # 24h
})

# Check if a grant exists
has_access = Grants.check("osi_abc", "osi_xyz", "read")
# => true | false

# Revoke a grant
{:ok, _} = Grants.revoke(grant.id)
```

### Validation Rules

- A grant cannot be created from an OS instance to itself (`source_os_id != target_os_id`).
- `expires_at` must be in the future when specified.
- Grants with a non-nil `revoked_at` are treated as inactive.

---

## Multi-Tenancy Isolation

OSA's platform supports multi-tenant deployments. Tenant isolation is enforced
at three levels:

### Hierarchy

```
User
 └── Tenant
      └── OS Instance (OSInstance)
```

Each user belongs to at most one tenant. Each tenant manages one or more OS
instances. Data at each level is isolated by ID — queries always filter by
`tenant_id` or `os_id` as appropriate.

### JWT Claims for Multi-Tenancy

```json
{
  "user_id":   "usr_01jn...",
  "email":     "alice@example.com",
  "role":      "admin",
  "tenant_id": "ten_01jn...",
  "os_id":     "osi_01jn..."
}
```

`tenant_id` and `os_id` are optional claims. They are present when the user is
authenticated within a specific tenant context.

```elixir
# Include in token generation
{:ok, tokens} = OptimalSystemAgent.Platform.Auth.generate_tokens(user,
  tenant_id: "ten_01jn...",
  os_id:     "osi_01jn..."
)
```

### Tenant Configuration

Tenant-level configuration (models, budget limits, enabled channels) is stored
in `OptimalSystemAgent.Tenant.Config` and loaded per-request from the JWT claims:

```elixir
tenant_id = get_in(claims, ["tenant_id"])
{:ok, config} = OptimalSystemAgent.Tenant.Config.get(tenant_id)
```

### Session Isolation

All session data (messages, memory, task queue) is keyed by `session_id`.
Session IDs are generated per-user-per-channel and are not shared across tenants.
Cross-tenant access requires an explicit grant via `Platform.Grants`.
