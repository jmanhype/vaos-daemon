# UX-001: No Clear Message When API Keys Are Missing

> **Severity:** UX
> **Status:** Open
> **Component:** `lib/optimal_system_agent/providers/registry.ex`, `lib/optimal_system_agent/channels/http.ex`
> **Reported:** 2026-03-14

---

## Summary

When a user configures a cloud provider (Anthropic, OpenAI, Groq, etc.) but
forgets to set the API key environment variable, the first LLM call fails with a
generic HTTP 401 or 403 error from the provider. The error is logged at
`:warning` level and surfaces to the user as "Provider error: HTTP 401" with no
actionable guidance on which key is missing or how to set it.

## Symptom

User starts OSA, types a message, and receives:

```
Error: Provider error: HTTP 401: {"error": {"message": "Invalid API Key"}}
```

There is no indication of which environment variable to set, where to obtain
a key, or whether the key was loaded at all.

## Root Cause

`provider_configured?/1` in `registry.ex` lines 637–644 checks for the presence
of a key:

```elixir
def provider_configured?(provider) do
  key = :"#{provider}_api_key"
  case Application.get_env(:optimal_system_agent, key) do
    nil -> false
    "" -> false
    _ -> true
  end
end
```

This function is public and called from `provider_info/1`, but it is never
invoked before an LLM call to produce a user-friendly warning. The error path
in `apply_provider/2` (line 492) catches the provider exception and returns
`{:error, "Provider error: #{Exception.message(e)}"}` — a technical string
not intended for end users.

The health endpoint (`http.ex` line 68) reports the active provider and model
but does not surface key validation status in a way that frontends check before
showing the chat interface.

## Impact

- New users who set a provider but forget the API key receive a confusing error
  on their first message.
- There is no pre-flight check; the error occurs mid-session after the user has
  already typed.
- Desktop app shows raw error strings in the chat bubble.

## Suggested Fix

1. Add a pre-flight check in the application startup that logs a clear warning
   for each configured but uncredentialed provider:

```elixir
# In application.ex start/2:
configured_providers = Providers.Registry.list_providers()
Enum.each(configured_providers, fn p ->
  unless p == :ollama or Providers.Registry.provider_configured?(p) do
    Logger.warning("[startup] Provider #{p} is registered but has no API key set. " <>
                   "Set #{p |> to_string() |> String.upcase()}_API_KEY in your .env")
  end
end)
```

2. Return a structured `{:error, :missing_api_key, provider}` tuple from
   `apply_provider/2` when an HTTP 401 is received, and translate it to a
   user-facing message in the Loop response handler.

## Workaround

Check `GET /api/v1/models` — the `configured?` field per provider indicates
whether a key is present. Also run `mix osa.chat /doctor` which calls
`cmd_doctor/2` and includes provider key status.
