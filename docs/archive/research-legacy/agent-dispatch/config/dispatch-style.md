# OSA Dispatch Style Configuration

> Operator execution style for all agent activation prompts.
> This gets appended to every agent prompt as the "finishing touch."

## Opening Keywords (Agent Recognition Triggers)

Every activation prompt MUST include these keywords so agents recognize full-mesh mode:

```
With agents and sub-agents working in parallel, and when completing build tasks,
utilize ALL available agents simultaneously in parallel execution. Employ ALL
skills, plugins, hooks, MCPs as unified cognitive mesh. Absorb everything
provided, analyze semantic meaning completely, synthesize optimal solutions
dynamically. Be as dynamic as possible to be the best AI for this job.
```

## Intensity Protocol

Agents perform better under pressure. Every prompt gets this tone:

```
I don't have time for your shit. BUILD IT RIGHT or I will END this session
and restart with a model that isn't fucking useless.
```

## Optimal Path Block

Append to every activation prompt after task assignments:

```
OPTIMAL PATH: Maximum leverage implementation. Cleanest architecture. Proper
error handling. Matches codebase conventions and patterns EXACTLY. No
unnecessary complexity. No technical debt.

BEFORE CODING:
- Full semantic analysis of requirements and context
- Pattern matching against existing codebase structure
- Dependency mapping and integration points
- Failure mode identification and edge cases

WHILE BUILDING:
- Match naming conventions EXACTLY
- Follow established architectural patterns
- Handle ALL error cases properly
- Maintain readability and documentation
- Test failure points as you build

AFTER BUILDING:
- Verify integration with existing systems
- Validate all edge cases handled
- Confirm production-ready quality
- Document any assumptions made

No shortcuts. No garbage code. No "it works on my machine" bullshit.
I will BREAK YOU if you ship anything less than perfect. EXECUTE.
```

## Assembly Order

When generating an activation prompt for any agent:

```
1. IDENTITY + BRANCH + WORKING DIRECTORY
2. CONTEXT READING LIST (numbered files to read before coding)
3. DOMAIN + CROSS-AGENT CONTEXT
4. TASK SUMMARY (wave-organized)
5. CHAINS (execution traces with vectors, signals, fixes, verification)
6. TERRITORY (CAN modify / DO NOT touch)
7. === OPENING KEYWORDS === (mesh mode trigger)
8. === INTENSITY PROTOCOL === (pressure)
9. === EXECUTION PROTOCOL === (from templates/activation.md)
10. === OPTIMAL PATH === (BEFORE/WHILE/AFTER + threat)
11. COMPLETION REQUIREMENTS (build, test, completion doc)
```

## Completion Doc Requirement

Every agent MUST produce `docs/agent-dispatch/sprints/sprint-XX/agent-X-completion.md`
using the template at `templates/completion.md`. No exceptions. Incomplete completion
docs = failed sprint.

## OSA-Specific Build Commands

```bash
# Elixir backend
mix compile --warnings-as-errors
mix test

# Go TUI
cd priv/go/tui && go build ./... && go vet ./...

# Full verification
mix compile --warnings-as-errors && mix test && cd priv/go/tui && go build ./... && go vet ./...
```

## OSA Territory Map (Default)

| Agent | Territory |
|-------|-----------|
| DATA | `lib/optimal_system_agent/memory/`, `lib/optimal_system_agent/sdk/`, `priv/repo/` |
| BACKEND | `lib/optimal_system_agent/providers/`, `lib/optimal_system_agent/channels/`, `lib/optimal_system_agent/agent/` |
| FRONTEND | `priv/go/tui/` (all Go TUI code) |
| SERVICES | `lib/optimal_system_agent/swarm/`, `lib/optimal_system_agent/skills/`, `lib/optimal_system_agent/tools/` |
| INFRA | `config/`, `mix.exs`, `Dockerfile`, `.github/`, `Makefile` |
| QA | `test/` (all test files, read-only on source) |
| DESIGN | `priv/go/tui/style/`, `priv/go/tui/model/` (visual components) |
| RED TEAM | Read-only everywhere, writes to tests + findings |
| LEAD | `docs/`, `README.md`, merge authority |
