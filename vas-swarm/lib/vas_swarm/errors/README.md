# VasSwarm Errors - ErrorResponse Module

## Overview

The `VasSwarm.Errors.ErrorResponse` module provides a unified, secure approach to HTTP error responses in VAS-Swarm APIs. It standardizes error format, prevents information leakage, and simplifies error handling across all HTTP endpoints.

## 📁 Structure

```
vas-swarm/lib/vas_swarm/errors/
├── error_response.ex              # Main ErrorResponse module
├── error_response/
│   └── backward_compat.ex         # Backward compatibility layer

vas-swarm/test/vas_swarm/errors/
└── error_response_test.exs        # Comprehensive test suite

vas-swarm/docs/
├── ERROR_RESPONSE_STRUCTURE.md    # Full specification and migration guide
└── ERROR_RESPONSE_QUICK_REFERENCE.md  # Common scenarios and examples
```

## 🎯 Key Features

### 1. **Unified JSON Structure**

All errors follow a consistent schema:

```json
{
  "status": "error",
  "code": "snake_case_code",
  "message": "Human-readable description",
  "details": { ... }
}
```

### 2. **Security-First Design**

- **Never leaks internal state**: Stack traces, config values, and prompts stay server-side
- **No dynamic error details**: All error messages are predefined
- **Safe changeset handling**: Validation errors are sanitized

### 3. **Developer-Friendly API**

```elixir
import VasSwarm.Errors.ErrorResponse

# Convenience functions
not_found(conn, "User not found")
unauthorized(conn, "Invalid token")
validation_failed(conn, "Email is required", %{email: ["is invalid"]})
from_changeset(conn, changeset)
```

### 4. **Backward Compatibility**

Drop-in replacement for existing `json_error/4`:

```elixir
import VasSwarm.Errors.ErrorResponse.BackwardCompat

# Same signature, safer implementation
json_error(conn, 401, "unauthorized", "Invalid token")
```

## 📖 Documentation

- **[Full Specification](ERROR_RESPONSE_STRUCTURE.md)** - Complete API reference, security policy, and migration guide
- **[Quick Reference](ERROR_RESPONSE_QUICK_REFERENCE.md)** - Common scenarios with copy-paste examples

## 🚀 Quick Start

```elixir
# In your route handler
defmodule MyApp.Routes.Users do
  import Plug.Router
  import VasSwarm.Errors.ErrorResponse

  post "/users" do
    case create_user(conn.body_params) do
      {:ok, user} -> json(conn, 201, %{user: user})
      {:error, %Ecto.Changeset{} = cs} -> from_changeset(conn, cs)
      {:error, :unauthorized} -> forbidden(conn)
      {:error, _} -> internal_error(conn)
    end
  end
end
```

## 🔒 Security Policy

### ❌ NEVER

```elixir
# Leak internal state
json_error(conn, 500, "error", inspect(reason))

# Expose stack traces
json_error(conn, 500, "error", Exception.message_stacktrace(e))

# Raw error reasons
json_error(conn, 422, "error", to_string(reason))
```

### ✅ ALWAYS

```elixir
# Use predefined codes
internal_error(conn)

# Log internally, respond generically
Logger.error("Failed: #{inspect(reason)}")
internal_error(conn)
```

## 📋 Standard Error Codes

| Code | Status | Description |
|------|--------|-------------|
| `invalid_request` | 400 | Malformed request |
| `invalid_json` | 400 | Invalid JSON body |
| `unauthorized` | 401 | Authentication failed |
| `forbidden` | 403 | Insufficient permissions |
| `not_found` | 404 | Resource missing |
| `conflict` | 409 | Resource conflict |
| `validation_failed` | 422 | Validation errors |
| `rate_limited` | 429 | Too many requests |
| `internal_error` | 500 | Server error |
| `service_unavailable` | 503 | Temporarily unavailable |
| `timeout` | 504 | Request timeout |

## 🧪 Testing

```bash
# Run all error response tests
mix test test/vas_swarm/errors/error_response_test.exs

# Run with coverage
mix test --cover test/vas_swarm/errors/
```

## 📦 Migration from Old Pattern

### Before

```elixir
def json_error(conn, status, error, details) do
  body = Jason.encode!(%{error: error, details: details})
  conn |> put_resp_content_type("application/json") |> send_resp(status, body)
end
```

### After

```elixir
import VasSwarm.Errors.ErrorResponse

json_error(conn, 404, "not_found", "User not found")
# Produces: {"status":"error","code":"not_found","message":"User not found","details":null}
```

## 🔗 Related Files

- `lib/vas_swarm/errors/error_response.ex` - Main implementation
- `lib/vas_swarm/errors/error_response/backward_compat.ex` - Compatibility layer
- `test/vas_swarm/errors/error_response_test.exs` - Test suite

## 📝 License

Part of the VAS-Swarm project.
