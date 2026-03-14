# Registering Components

Audience: developers who have written a tool, skill, command, hook, or channel
adapter and now need to make OSA aware of it.

All registrations happen at runtime, not at compile time. You can register a
component from `init/1` of a supervised process, from a Mix task, from IEx,
or from application startup code.

---

## Register a Tool

Tools are Elixir modules that implement `OptimalSystemAgent.Tools.Behaviour`.
Once registered, the tool becomes available to the LLM for function calling.

```elixir
OptimalSystemAgent.Tools.Registry.register(MyApp.Tools.WeatherTool)
```

Registration recompiles the goldrush `:osa_tool_dispatcher` bytecode module
automatically. New tools are available to the LLM immediately — no restart
required.

To register at application boot, call `register/1` from the `init/1` of a
supervised process (after `Tools.Registry` is started under Infrastructure):

```elixir
# In your service's init/1, or from Supervisors.Extensions init
OptimalSystemAgent.Tools.Registry.register(MyApp.Tools.WeatherTool)
OptimalSystemAgent.Tools.Registry.register(MyApp.Tools.CalendarTool)
```

List all registered tools:

```elixir
OptimalSystemAgent.Tools.Registry.list_tools()
```

---

## Register a Skill

Skills are prompt-only definitions. They inject structured instructions into
the agent's context without requiring Elixir code. There are two ways to
register a skill.

### Option A: SKILL.md file

Drop a markdown file in `~/.osa/skills/`. OSA discovers skill files at boot
and when `Tools.Registry` is explicitly reloaded.

File format (`~/.osa/skills/my_skill.md`):

```markdown
---
name: my_skill
description: Brief description shown to the LLM when selecting skills
tools:
  - file_read
  - web_search
---

# My Skill

Instructions for the agent. Write as you would write a system prompt section.
The agent reads this verbatim when the skill is activated.

## Steps

1. First, do this.
2. Then do that.
3. Return the result in this format.
```

The `tools` list in the YAML frontmatter tells the router which tools this
skill expects to use. It does not restrict other tools — it is informational.

### Option B: Programmatic registration

```elixir
OptimalSystemAgent.Tools.Registry.register_skill(%{
  name: "my_skill",
  description: "Brief description",
  instructions: "Full skill instructions as a string",
  tools: ["file_read", "web_search"]
})
```

---

## Register a Command

Slash commands are shortcuts that expand into prompt templates or call Elixir
functions directly. Commands are stored in ETS and optionally persisted to
`~/.osa/commands/`.

### File-based commands (recommended)

Create a markdown file in `~/.osa/commands/`:

```markdown
---
name: standup
description: Generate a daily standup summary
---

Review my recent activity across all sessions from today and generate a
standup update. Include:
- What I accomplished yesterday
- What I am working on today
- Any blockers or risks
```

The command is accessible as `/standup` in any chat channel.

### Programmatic registration

```elixir
OptimalSystemAgent.Commands.register("my_command", fn _args ->
  # Return the prompt string or {:ok, response_string}
  "Perform my custom action and report the result."
end)
```

The handler receives any arguments the user typed after the command name as a
single string. It must return a string (treated as a user message to the agent
loop) or `{:ok, string}` (treated as a direct response, bypassing the agent
loop).

---

## Register a Hook

Hooks intercept the agent lifecycle. Register a hook from any supervised
process after `Agent.Hooks` starts (under `Supervisors.AgentServices`).

```elixir
alias OptimalSystemAgent.Agent.Hooks

Hooks.register(%{
  name: "my_audit_hook",
  event: :pre_tool_use,
  priority: 20,
  handler: fn payload ->
    # Log every tool call for audit purposes
    Logger.info("[audit] tool=#{payload[:tool]} session=#{payload[:session_id]}")
    {:ok, payload}
  end
})
```

Priority controls execution order within an event. Lower numbers run first.
Built-in hooks use priorities 8–90. Safe ranges for custom hooks:

| Priority range | Meaning |
|----------------|---------|
| 1–7 | Runs before all built-ins. Use only if your hook must see the raw payload. |
| 11–79 | Standard range for custom hooks. |
| 80–99 | Runs after most built-ins. Good for post-processing and logging. |
| 100+ | Runs last. Good for telemetry and non-critical side effects. |

### Hook return values

| Return | Meaning |
|--------|---------|
| `{:ok, payload}` | Continue. Pass the (possibly modified) payload to the next hook. |
| `{:block, reason}` | Stop the chain. The tool call is rejected. Only meaningful for `:pre_tool_use`. |
| `:skip` | Skip this hook silently. The payload passes through unchanged. |

### Available hook events

```
:pre_tool_use     — before every tool call (can block)
:post_tool_use    — after every tool call (async, cannot block)
:pre_compact      — before context compaction
:session_start    — when a new session is created
:session_end      — when a session terminates
:pre_response     — before the final response is sent
:post_response    — after the response is delivered
```

---

## Register a Channel

Channel adapters run under `OptimalSystemAgent.Channels.Supervisor`, a
`DynamicSupervisor`. Start a channel adapter as a dynamic child:

```elixir
DynamicSupervisor.start_child(
  OptimalSystemAgent.Channels.Supervisor,
  {MyApp.Channels.MyAdapter, config: my_config}
)
```

Channel adapters must implement `OptimalSystemAgent.Channels.Behaviour`. See
[Extending the Runtime](./extending-the-runtime.md) for the full adapter
contract.

The built-in `Channels.Starter` GenServer starts configured channel adapters
at boot by iterating over adapters whose required configuration (e.g., API
tokens) is present. Follow the same pattern for your adapter: check for
required config in `start_link/1` and return `{:error, :not_configured}` if
it is missing rather than crashing.

---

## Verify Registration

```elixir
# Tools
OptimalSystemAgent.Tools.Registry.list_tools()
|> Enum.map(& &1.name)

# Hooks
OptimalSystemAgent.Agent.Hooks.list_hooks()

# Commands
# (inspect the ETS table directly)
:ets.tab2list(:osa_commands)
```

---

## Related

- [Extending the Runtime](./extending-the-runtime.md) — implement the tool, skill, and channel behaviours
- [Creating a Service](./creating-a-service.md) — wrap your registrations in a supervised GenServer
