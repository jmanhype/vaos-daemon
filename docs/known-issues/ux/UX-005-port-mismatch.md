# UX-005: Desktop Client Uses Port 9089 but Server Defaults to 8089

> **Severity:** UX
> **Status:** Open
> **Component:** `desktop/src/lib/api/client.ts`, `lib/mix/tasks/osa.serve.ex`
> **Reported:** 2026-03-14

---

## Summary

The desktop Tauri application hard-codes the backend URL as
`http://127.0.0.1:9089` in `client.ts` line 24:

```typescript
export const BASE_URL = "http://127.0.0.1:9089";
```

The backend default port, set in `mix daemon.serve` (line 27 of `osa.serve.ex`)
and `config.exs`, is `8089`:

```elixir
port = Application.get_env(:daemon, :http_port, 8089)
```

The desktop app and the backend are therefore out-of-sync by default. A fresh
install that starts both with default configuration will have the desktop unable
to connect to the backend.

## Symptom

Desktop app starts, health check to `http://127.0.0.1:9089/health` fails with
`ERR_CONNECTION_REFUSED`. The connection indicator shows red. All API calls fail.
The app is non-functional until the user manually starts the backend on port
9089 or reconfigures one side.

## Root Cause

Two independent defaults were set during development and were never reconciled:

- `desktop/src/lib/api/client.ts:24` — `BASE_URL = "http://127.0.0.1:9089"`
- `lib/mix/tasks/osa.serve.ex:27` — `http_port` defaults to `8089`
- `config/config.exs` — `http_port: 8089`

There is no runtime configuration mechanism in the desktop app to discover the
correct port. The `settingsStore.ts` has a `serverUrl` field but it is not
read by `client.ts`; `BASE_URL` is a module-level constant evaluated at import
time.

## Impact

- All users on a fresh install cannot use the desktop app without manual
  reconfiguration.
- The discrepancy is non-obvious; the error appears as a generic network failure
  with no hint that ports are mismatched.
- Documentation and README reference `8089` for curl examples but the desktop
  app expects `9089`.

## Suggested Fix

**Option A (recommended):** Standardise on port `8089` in both places:
```typescript
// client.ts
export const BASE_URL = "http://127.0.0.1:8089";
```

**Option B:** Make `BASE_URL` dynamic by reading from the Tauri store or an
environment variable baked in at build time:
```typescript
export const BASE_URL =
  import.meta.env.VITE_BACKEND_URL ?? "http://127.0.0.1:8089";
```

**Option C:** Use the `serverUrl` from `settingsStore.ts` as the base URL,
allowing users to configure a non-default port in the Settings page.

## Workaround

Start the backend on port 9089 explicitly:
```bash
DAEMON_HTTP_PORT=9089 mix daemon.serve
```
Or change `BASE_URL` in `client.ts` to `http://127.0.0.1:8089` and rebuild
the desktop app.
