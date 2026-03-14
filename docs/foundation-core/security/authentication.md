# Authentication

Audience: operators deploying OSA as an HTTP API server, and developers
integrating with the HTTP channel.

OSA's HTTP channel uses JWT HS256 authentication. The local CLI does not
require authentication by default. Authentication is opt-in and must be
explicitly enabled for production deployments.

---

## Enabling Authentication

Set two environment variables before starting OSA:

```bash
export OSA_SHARED_SECRET="your-secret-key-at-least-32-chars"
export OSA_REQUIRE_AUTH=true
```

When `OSA_REQUIRE_AUTH` is `true`, all HTTP API endpoints except `/health`
and `/auth/token` require a valid `Authorization: Bearer <token>` header.

When `OSA_SHARED_SECRET` is not set, OSA generates an ephemeral random secret
at startup. This secret is printed to the log as a warning and is not suitable
for production because it changes on every restart:

```
[warning] HTTP Auth: No shared secret configured. Generated ephemeral secret
for this session. Set OSA_SHARED_SECRET env var for production.
```

---

## Token Format

OSA uses HMAC-SHA256 signed JWTs (alg: `HS256`).

### Access Token

- Issued by `POST /auth/token` or `POST /auth/login`
- Lifetime: 15 minutes (900 seconds)
- `type` claim: absent (access tokens have no type claim)

### Refresh Token

- Issued alongside the access token
- Lifetime: 7 days (604,800 seconds)
- `type` claim: `"refresh"`

### JWT Claims

```json
{
  "user_id":   "usr_01jn4k5r9ze4q8w0yxp2c3m6v7",
  "email":     "alice@example.com",
  "role":      "admin",
  "iat":       1710000000,
  "exp":       1710000900,

  // Optional — present on multi-tenant platform deployments
  "tenant_id": "ten_01jn4kx8q2a5b6c7d8e9f0g1h2",
  "os_id":     "osi_01jn4m2n3p4q5r6s7t8u9v0w1x"
}
```

### Roles

| Role | Description |
|---|---|
| `"admin"` | Full access. Can manage channels, providers, and other users. |
| `"user"` | Standard agent access. Can send messages and use tools. |
| `"viewer"` | Read-only. Can query state and history but cannot invoke the agent. |

---

## Token Generation

### Via Platform.Auth (Elixir)

`OptimalSystemAgent.Platform.Auth` handles user registration, login, and token
issuance for the multi-tenant platform.

```elixir
# Register a new user
{:ok, %{user: user, token: access_token, refresh_token: refresh_token}} =
  OptimalSystemAgent.Platform.Auth.register(%{
    email:        "alice@example.com",
    password:     "securepassword123",
    display_name: "Alice"
  })

# Login
{:ok, %{user: user, token: access_token, refresh_token: refresh_token}} =
  OptimalSystemAgent.Platform.Auth.login(%{
    email:    "alice@example.com",
    password: "securepassword123"
  })

# Generate tokens for an existing user (e.g. for service accounts)
{:ok, %{token: access_token, refresh_token: refresh_token}} =
  OptimalSystemAgent.Platform.Auth.generate_tokens(user, tenant_id: "ten_abc", os_id: "osi_xyz")
```

Password hashing uses **Bcrypt** via the `bcrypt_elixir` library. Passwords
are never stored in plain text. The `password_hash` column in the users table
stores only the Bcrypt hash.

### Via HTTP API

```bash
# Obtain tokens
curl -X POST http://localhost:4000/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "password": "securepassword123"}'

# Response
{
  "token": "eyJhbGciOiJIUzI1NiJ9...",
  "refresh_token": "eyJhbGciOiJIUzI1NiJ9...",
  "expires_in": 900
}
```

### Using the Access Token

```bash
curl http://localhost:4000/api/agent/messages \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9..."
```

### Refreshing Tokens

```bash
curl -X POST http://localhost:4000/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"refresh_token": "eyJhbGciOiJIUzI1NiJ9..."}'

# Response
{
  "token": "eyJhbGciOiJIUzI1NiJ9...",
  "refresh_token": "eyJhbGciOiJIUzI1NiJ9...",
  "expires_in": 900
}
```

---

## Token Verification

`OptimalSystemAgent.Channels.HTTP.Auth.verify_token/1` validates:

1. Token has three dot-separated segments (header, payload, signature).
2. Header `alg` is `"HS256"`. Other algorithms are rejected.
3. HMAC-SHA256 signature is valid against the configured secret.
4. `exp` claim is in the future.
5. `user_id` claim is present.

```elixir
case OptimalSystemAgent.Channels.HTTP.Auth.verify_token(bearer_token) do
  {:ok, claims} ->
    # claims = %{"user_id" => "...", "email" => "...", "role" => "...", ...}
    :ok
  {:error, :invalid_token} ->
    # Reject the request
    {:error, 401}
end
```

Signature comparison uses `Plug.Crypto.secure_compare/2` (constant-time)
to prevent timing attacks.

---

## Local / Development Mode

When `OSA_REQUIRE_AUTH` is not set or is `false`:

- The HTTP API is unauthenticated.
- The CLI operates without tokens.
- An ephemeral JWT secret is generated if `OSA_SHARED_SECRET` is absent.

Development mode is the default to reduce friction during local development.
Always set `OSA_REQUIRE_AUTH=true` before any network-accessible deployment.

---

## Generating a Shared Secret

Use a cryptographically secure method:

```bash
# OpenSSL (recommended)
openssl rand -base64 48

# Elixir one-liner
elixir -e 'IO.puts(:crypto.strong_rand_bytes(48) |> Base.url_encode64())'
```

The secret must be at least 32 characters. Longer is better — 48+ bytes
provides 384 bits of entropy.

---

## Environment Variable Reference

| Variable | Required | Description |
|---|---|---|
| `OSA_SHARED_SECRET` | No (dev only) | HS256 signing secret. Also accepted as `JWT_SECRET`. |
| `OSA_REQUIRE_AUTH` | No (dev only) | Set to `"true"` to enforce JWT on all HTTP endpoints. |

Lookup priority for the secret: `Application.get_env(:optimal_system_agent, :jwt_secret)` →
`Application.get_env(:optimal_system_agent, :shared_secret)` →
`JWT_SECRET` env var → `OSA_SHARED_SECRET` env var → ephemeral generated secret.
