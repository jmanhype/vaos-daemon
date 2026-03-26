# Platform: Tenants

Tenants are the top-level organizational boundary in the MIOSA platform. Each tenant owns OS instances and manages its own members. Tenants are backed by the `tenants`, `tenant_members`, and `tenant_invites` Ecto schemas.

---

## Tenant Schema

| Field | Type | Constraints |
|-------|------|-------------|
| `id` | binary_id (UUID) | Auto-generated |
| `name` | string | Required, max 255 chars |
| `slug` | string | Required, unique, max 100, `[a-z0-9\-]+` |
| `owner_id` | binary_id | Required |
| `plan` | string | `free`, `starter`, `pro`, `enterprise` |
| `settings` | map | JSON, default `{}` |

The `settings` map is freeform — tenants can store per-tenant configuration here (feature flags, custom prompts, model overrides, etc.).

---

## Tenant Member Roles

Members have one of three roles:

| Role | Capabilities |
|------|-------------|
| `owner` | Full control, can delete tenant |
| `admin` | Manage members, configure instances |
| `member` | Use instances, no admin access |

---

## API (`Platform.Tenants`)

### Create a tenant

```elixir
{:ok, tenant} = Platform.Tenants.create(owner_id, %{
  "name" => "Acme Corp",
  "slug" => "acme-corp",
  "plan" => "pro"
})
```

Runs as an `Ecto.Multi`: inserts the tenant, then inserts the owner as a `member` with role `"owner"`. Fails atomically if either step fails.

### Fetch and list

```elixir
tenant = Platform.Tenants.get("tenant-uuid")
tenants = Platform.Tenants.list_for_user("user-uuid")
```

`list_for_user/1` returns all tenants where the user is a member (any role).

### Update

```elixir
{:ok, tenant} = Platform.Tenants.update("tenant-uuid", %{"plan" => "enterprise"})
```

### Delete

```elixir
{:ok, tenant} = Platform.Tenants.delete("tenant-uuid")
```

Hard-deletes the tenant record. OS instances should be cleaned up separately before deletion.

### Member management

```elixir
# List members
members = Platform.Tenants.list_members("tenant-uuid")

# Invite a member (generates a token, expires in 7 days)
{:ok, invite} = Platform.Tenants.invite_member("tenant-uuid", "bob@example.com", "member")

# Accept an invite (requires the user to exist)
{:ok, invite} = Platform.Tenants.accept_invite(invite_token)

# Remove a member
:ok = Platform.Tenants.remove_member("tenant-uuid", "user-uuid")

# Change a member's role
:ok = Platform.Tenants.update_member_role("tenant-uuid", "user-uuid", "admin")
```

Invite acceptance runs as an `Ecto.Multi`: marks the invite as accepted, looks up the user by email, inserts the member record. Returns `{:error, :user_not_found}` if no account exists for the invited email.

---

## TenantMember Schema

| Field | Type | Description |
|-------|------|-------------|
| `tenant_id` | binary_id | Parent tenant |
| `user_id` | binary_id | Member user |
| `role` | string | `owner`, `admin`, or `member` |
| `joined_at` | utc_datetime | When they joined |

Unique constraint on `(tenant_id, user_id)` — a user can only be a member once per tenant.

---

## TenantInvite Schema

| Field | Type | Description |
|-------|------|-------------|
| `tenant_id` | binary_id | Target tenant |
| `email` | string | Invitee email |
| `role` | string | Role to assign on accept |
| `token` | string | Auto-generated URL-safe token |
| `expires_at` | utc_datetime | 7 days from creation |
| `accepted_at` | utc_datetime | Set when accepted |

Token is generated with `32 random bytes |> Base.url_encode64`. Unique constraint on `(tenant_id, email)` — only one pending invite per email per tenant.

---

## Per-Tenant Configuration

The `settings` map is the primary mechanism for per-tenant customization. There is no fixed schema — Daemon reads settings at runtime where needed. Typical keys:

| Key | Description |
|-----|-------------|
| `"default_model"` | Override the default LLM model for this tenant |
| `"allowed_tools"` | Restrict tool access list |
| `"system_prompt_prefix"` | Prepend to every agent system prompt |
| `"rate_limit_override"` | Custom rate limits for this tenant |
| `"branding"` | Custom name/logo for the web UI |

---

## HTTP Routes (`PlatformRoutes`)

Tenant CRUD is exposed under `/api/v1/platform/` (JWT required):

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/v1/platform/tenants` | List tenants for current user |
| `POST` | `/api/v1/platform/tenants` | Create a tenant |
| `GET` | `/api/v1/platform/tenants/:id` | Get a tenant |
| `PUT` | `/api/v1/platform/tenants/:id` | Update a tenant |
| `DELETE` | `/api/v1/platform/tenants/:id` | Delete a tenant |
| `GET` | `/api/v1/platform/tenants/:id/members` | List members |
| `POST` | `/api/v1/platform/tenants/:id/invite` | Send invite |
| `POST` | `/api/v1/platform/tenants/:id/members/:uid/role` | Update member role |
| `DELETE` | `/api/v1/platform/tenants/:id/members/:uid` | Remove member |

Tenant config is also managed via:

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/v1/tenant-config` | Get current tenant config |
| `PUT` | `/api/v1/tenant-config` | Update tenant config |

---

## See Also

- [auth.md](auth.md) — Authentication and grants
- [instances.md](instances.md) — OS instances within tenants
