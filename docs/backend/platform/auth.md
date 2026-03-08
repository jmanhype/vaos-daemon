# Platform: Auth

OSA has two distinct authentication layers. The channel-level layer (`Channels.HTTP.Auth`) handles session tokens for the HTTP API. The platform-level layer (`Platform.Auth`) handles user accounts, registration, and multi-tenant identity for the MIOSA platform.

---

## Channel Auth (`Channels.HTTP.Auth`)

HS256 JWT authentication for the HTTP channel. Described in detail in [../channels/http.md](../channels/http.md). This section covers its role as the token-issuing authority shared by both auth layers.

### Token issuance

```elixir
# Access token (15 min)
token = Channels.HTTP.Auth.generate_token(%{
  "user_id" => "user-abc",
  "email" => "alice@example.com",
  "role" => "member"
})

# Refresh token (7 days)
refresh = Channels.HTTP.Auth.generate_refresh_token(%{...})
```

### Token verification

```elixir
case Channels.HTTP.Auth.verify_token(bearer_token) do
  {:ok, claims} -> claims["user_id"]
  {:error, :invalid_token} -> :unauthorized
end
```

Validation steps (in order):
1. Split into header, payload, signature segments.
2. Decode header — require `"alg": "HS256"`.
3. Decode payload.
4. Verify HMAC-SHA256 signature using `Plug.Crypto.secure_compare/2`.
5. Check `exp` claim against current Unix time.

### Refresh flow

```elixir
{:ok, %{token: new_access, refresh_token: new_refresh, expires_in: 900}} =
  Channels.HTTP.Auth.refresh(old_refresh_token)
```

Refresh tokens carry `"type": "refresh"` in claims. Using an access token as a refresh token returns `{:error, :not_refresh_token}`.

---

## Platform Auth (`Platform.Auth`)

Ecto-backed user authentication for the MIOSA platform. Stores users in the `users` table via `Platform.Repo`.

### Registration

```elixir
{:ok, %{user: user, token: token, refresh_token: refresh}} =
  Platform.Auth.register(%{
    email: "alice@example.com",
    password: "secure-password",
    display_name: "Alice"
  })
```

Password is hashed with Bcrypt via the `User` changeset. On success, an access + refresh token pair is issued immediately.

### Login

```elixir
{:ok, %{user: user, token: token, refresh_token: refresh}} =
  Platform.Auth.login(%{email: "alice@example.com", password: "secure-password"})
```

On invalid credentials, `Bcrypt.no_user_verify/0` is called (constant-time dummy check) before returning `{:error, :invalid_credentials}` — prevents user enumeration via timing.

Last login timestamp is updated on each successful login.

### Token claims

Platform tokens include:

| Claim | Required | Source |
|-------|----------|--------|
| `user_id` | Yes | `user.id` |
| `email` | Yes | `user.email` |
| `role` | Yes | `user.role` |
| `tenant_id` | Optional | From `opts` |
| `os_id` | Optional | From `opts` |

Tenant-scoped and OS-scoped tokens are issued by passing opts:

```elixir
{:ok, tokens} = Platform.Auth.generate_tokens(user, tenant_id: "t-123", os_id: "os-456")
```

### Other functions

| Function | Description |
|----------|-------------|
| `Platform.Auth.refresh/1` | Delegates to `Channels.HTTP.Auth.refresh/1` |
| `Platform.Auth.logout/1` | No-op (token blacklisting deferred) |
| `Platform.Auth.get_user/1` | Fetch user by ID from Repo |

---

## Platform Auth Routes (`HTTP.API.PlatformAuthRoutes`)

HTTP endpoints for platform-level auth (bypass JWT — no Bearer token required):

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v1/platform/auth/register` | Register new user |
| `POST` | `/api/v1/platform/auth/login` | Login with email/password |
| `POST` | `/api/v1/platform/auth/refresh` | Refresh access token |
| `POST` | `/api/v1/platform/auth/logout` | Logout (clears session) |

---

## Grants / Cross-OS Permissions (`Platform.Grants`)

The Grants system controls which OS instances can access resources on other OS instances. Stored in the `cross_os_grants` Ecto schema.

### Grant fields

| Field | Type | Description |
|-------|------|-------------|
| `source_os_id` | UUID | Granting OS instance |
| `target_os_id` | UUID | Receiving OS instance |
| `granted_by` | UUID | User who created the grant |
| `grant_type` | string | `read`, `write`, `execute`, or `admin` |
| `resource_pattern` | string | Optional glob, e.g. `"agents/*"`, `"data/shared/*"` |
| `expires_at` | datetime | Optional expiry |
| `revoked_at` | datetime | Set when revoked (soft delete) |

Constraints:
- Self-grants are rejected at changeset validation level.
- Expiry must be in the future.

### API

```elixir
# Create
{:ok, grant} = Platform.Grants.create(%{
  source_os_id: "os-abc",
  target_os_id: "os-xyz",
  granted_by: "user-123",
  grant_type: "read"
})

# Check (returns boolean)
Platform.Grants.check("os-abc", "os-xyz", "read")

# Revoke
:ok = Platform.Grants.revoke(grant.id)

# List (active grants for an OS instance)
grants = Platform.Grants.list("os-abc")
```

`list/1` returns grants where the OS is either the source or target, and `revoked_at` is nil.

---

## User Schema (`Platform.Schemas.User`)

Ecto schema for the `users` table. Key fields:

| Field | Type | Description |
|-------|------|-------------|
| `id` | binary_id | UUID, auto-generated |
| `email` | string | Unique, required |
| `password_hash` | string | Bcrypt hash |
| `display_name` | string | Display name |
| `role` | string | `"user"`, `"admin"`, etc. |
| `last_login_at` | utc_datetime | Set on login |

---

## See Also

- [tenants.md](tenants.md) — Multi-tenancy
- [instances.md](instances.md) — OS instances
- [../channels/http.md](../channels/http.md) — HTTP channel auth middleware
