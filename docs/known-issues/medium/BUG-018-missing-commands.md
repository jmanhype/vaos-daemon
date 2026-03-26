# BUG-018: /budget, /thinking, /export, /machines, /providers Have No Handlers

> **Severity:** MEDIUM
> **Status:** Open
> **Component:** `lib/daemon/commands.ex`, `lib/daemon/commands/agents.ex`
> **Reported:** 2026-03-14

---

## Summary

Five commands appear in the `builtin_commands/0` list in `commands.ex` (lines
291–295) and are categorised as `"info"` in `category_for/1` (line 132), but
their handler functions either do not exist or return stub output:

- `/budget` → `&Agents.cmd_budget/2`
- `/thinking` → `&Agents.cmd_thinking/2`
- `/export` → `&Data.cmd_export/2`
- `/machines` → `&Agents.cmd_machines/2`
- `/providers` → `&Model.cmd_providers/2`

## Symptom

Typing any of these commands in the CLI produces no output or a generic
"not implemented" string. They appear in `/help` output, creating a false
impression of working functionality.

## Root Cause

The commands are registered in `builtin_commands/0`:

```elixir
# lib/daemon/commands.ex lines 291–295
{"budget",    "Token and cost budget status",  &Agents.cmd_budget/2},
{"thinking",  "Toggle extended thinking mode", &Agents.cmd_thinking/2},
{"export",    "Export session to file",        &Data.cmd_export/2},
{"machines",  "List connected machines",       &Agents.cmd_machines/2},
{"providers", "List available LLM providers",  &Model.cmd_providers/2},
```

The underlying handler modules (`Commands.Agents`, `Commands.Data`,
`Commands.Model`) define these functions but the implementations are either empty
or call GenServer APIs that have not been connected to a data source. For example,
`cmd_budget/2` calls `Daemon.Agent.Treasury` which exists but
`Treasury.budget_summary/0` returns `{:error, :not_implemented}`.

`cmd_machines/2` calls `Daemon.Machines.list/0` which queries the
machines ETS table. The table exists, but if no machines have registered
(fleet is empty), the output is `"No machines connected"` — which is technically
correct but not clearly communicated to the user.

## Impact

- Users cannot check their token/cost budget from the CLI.
- `/thinking` cannot be toggled from the CLI; users must restart with environment
  config.
- `/providers` gives no output, forcing users to check `mix daemon.chat --help`.
- Session export is not accessible from the CLI.

## Suggested Fix

Prioritise `/budget` and `/providers` as they are most commonly needed:

**`/providers`**: Read from `Providers.Registry.list_providers/0` and format:
```elixir
def cmd_providers(_arg, _session_id) do
  providers = MiosaProviders.Registry.list_providers()
  lines = Enum.map_join(providers, "\n", fn p ->
    configured = if MiosaProviders.Registry.provider_configured?(p), do: "(configured)", else: ""
    "  #{p} #{configured}"
  end)
  {:command, "Available providers:\n#{lines}"}
end
```

**`/budget`**: Connect to `Agent.Treasury` or `Telemetry.Metrics` for cost data.

**`/thinking`**: Toggle `Application.put_env(:daemon, :thinking_enabled, ...)`.

## Workaround

- `/providers`: Use `GET /api/v1/models` to see available providers.
- `/budget`: Use `GET /api/v1/analytics` for usage data.
- `/machines`: Use `GET /api/v1/machines`.
- `/export`: Use `GET /api/v1/sessions/:id/messages` to download session data.
