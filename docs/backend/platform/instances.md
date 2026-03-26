# Platform: OS Instances

An OS instance is a sandboxed, tenant-scoped deployment of Daemon. Each instance belongs to a tenant and an owner. Multiple users can be members of an instance with role-based access. Instances are managed via `Platform.OsInstances` and the `OsInstance` Ecto schema.

---

## OsInstance Schema

| Field | Type | Description |
|-------|------|-------------|
| `id` | binary_id (UUID) | Auto-generated |
| `tenant_id` | binary_id | Parent tenant |
| `owner_id` | binary_id | Creator/owner user |
| `name` | string | Display name |
| `slug` | string | URL-safe identifier, unique within tenant |
| `status` | string | Lifecycle state |
| `template_type` | string | Instance type/template |
| `config` | map | Per-instance configuration JSON |
| `sandbox_id` | string | Associated sandbox identifier |
| `sandbox_url` | string | Sandbox access URL |

### Status lifecycle

| Status | Meaning |
|--------|---------|
| `provisioning` | Being set up (initial state) |
| `active` | Running and accessible |
| `suspended` | Temporarily disabled |
| `stopped` | Shut down |
| `deleting` | Soft-delete initiated |

### Template types

| Template | Description |
|----------|-------------|
| `business_os` | Business operations agent |
| `content_os` | Content creation agent |
| `agency_os` | Multi-agent agency setup |
| `dev_os` | Developer assistant |
| `data_os` | Data analysis agent |
| `blank` | Empty instance, no preset |

---

## API (`Platform.OsInstances`)

### Create an instance

```elixir
{:ok, instance} = Platform.OsInstances.create("tenant-uuid", "user-uuid", %{
  "name" => "My Dev Assistant",
  "slug" => "dev-assistant",
  "template_type" => "dev_os"
})
# instance.status == "provisioning"
```

### Fetch and list

```elixir
instance = Platform.OsInstances.get("os-uuid")
instances = Platform.OsInstances.list("tenant-uuid")  # newest first
```

### Update

```elixir
{:ok, instance} = Platform.OsInstances.update("os-uuid", %{
  "status" => "active",
  "sandbox_id" => "sb-xyz",
  "sandbox_url" => "https://sandbox.example.com/sb-xyz"
})
```

### Delete (soft)

```elixir
{:ok, instance} = Platform.OsInstances.delete("os-uuid")
# Sets status to "deleting" — does not hard-delete
```

---

## Member Management

OS instances have their own membership layer, separate from tenant membership.

### OsInstanceMember Schema

| Field | Type | Description |
|-------|------|-------------|
| `os_instance_id` | binary_id | Parent instance |
| `user_id` | binary_id | Member user |
| `role` | string | Member role |
| `permissions` | map | Optional fine-grained permissions map |

### API

```elixir
# Add a member
{:ok, member} = Platform.OsInstances.add_member("os-uuid", "user-uuid", "member")

# Remove a member
:ok = Platform.OsInstances.remove_member("os-uuid", "user-uuid")

# List members
members = Platform.OsInstances.list_members("os-uuid")
```

---

## Instance Access Tokens

`OsInstances.enter/2` verifies membership and issues a scoped JWT with `os_id` in claims:

```elixir
{:ok, token} = Platform.OsInstances.enter("os-uuid", "user-uuid")
# token claims include: user_id, os_id
```

Returns `{:error, :not_member}` if the user is not a member of the instance.

This scoped token can then be used to authenticate HTTP API calls where the instance context is required (e.g. `/api/v1/sessions`, `/api/v1/orchestrate`).

---

## Cross-OS Grants

Permissions between OS instances are managed by `Platform.Grants`. An instance can grant another instance access to specific resource patterns. See [auth.md](auth.md) for full details.

```elixir
# Allow "os-b" to read agent outputs from "os-a"
Platform.Grants.create(%{
  source_os_id: "os-a",
  target_os_id: "os-b",
  granted_by: "user-uuid",
  grant_type: "read",
  resource_pattern: "agents/*"
})

Platform.Grants.check("os-a", "os-b", "read")  # => true
```

---

## HTTP Routes

OS instance CRUD is under `/api/v1/platform/` (JWT required):

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/v1/platform/os-instances` | List instances for current tenant |
| `POST` | `/api/v1/platform/os-instances` | Create an instance |
| `GET` | `/api/v1/platform/os-instances/:id` | Get an instance |
| `PUT` | `/api/v1/platform/os-instances/:id` | Update an instance |
| `DELETE` | `/api/v1/platform/os-instances/:id` | Soft-delete an instance |
| `POST` | `/api/v1/platform/os-instances/:id/enter` | Get scoped access token |
| `POST` | `/api/v1/platform/os-instances/:id/members` | Add member |
| `DELETE` | `/api/v1/platform/os-instances/:id/members/:uid` | Remove member |
| `GET` | `/api/v1/platform/os-instances/:id/grants` | List grants |
| `POST` | `/api/v1/platform/os-instances/:id/grants` | Create a grant |
| `DELETE` | `/api/v1/platform/os-instances/:id/grants/:gid` | Revoke a grant |

---

## See Also

- [auth.md](auth.md) — Auth, grants, and permissions
- [tenants.md](tenants.md) — Tenant management
- [amqp.md](amqp.md) — Cross-instance event propagation
