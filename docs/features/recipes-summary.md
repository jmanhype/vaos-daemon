# Recipe System — Testing Summary

**Date:** March 6, 2026  
**Tested by:** Javaris  
**Status:** ✅ Fully operational — 12 recipes, fresh-session flow, context warning

---

## Overview

The Recipe system (`lib/daemon/recipes/recipe.ex`, ~380 lines) provides structured multi-step workflows for complex tasks like code reviews, debugging, and app scaffolding.

## Test Results

| Function | Status | Notes |
|----------|--------|-------|
| `Recipe.list()` | ✅ Pass | Returns all 12 recipes from `priv/recipes/` (+ 5 fallbacks in `examples/workflows/`) |
| `Recipe.load("code-review")` | ✅ Pass | Loads full recipe with steps, signal modes, tools |
| `Recipe.run()` | ✅ Pass | Works via TUI `/recipe` command — fresh session, 0% context |
| `/recipe` (TUI) | ✅ Pass | Lists all recipes, triggers `new_session_prompt` flow |
| `/recipe code-review` (TUI) | ✅ Pass | Creates fresh session → SSE reconnect → auto-submits prompt |
| `/recipe-create` (TUI) | ✅ Pass | Scaffolds new recipe JSON at `.daemon/recipes/` |

## Available Recipes (12)

| Slug | Steps | Purpose |
|------|-------|---------|
| `add-feature` | 7 | Requirements → Plan → Implement → Test → Review → Document → Ship |
| `build-fullstack-app` | 10 | Complete app: frontend, backend, DB, deploy pipeline |
| `build-rest-api` | 9 | Full REST API from requirements to deployment |
| `code-review` | 5 | Understand → Check Correctness → Security Audit → Performance → Feedback |
| `content-campaign` | 7 | Content marketing: research through promotion and analysis |
| `debug-production-issue` | 7 | Reproduce → Isolate → Hypothesize → Test → Fix → Verify → Prevent |
| `migrate-database` | 8 | Audit → Plan → Backup → Migrate → Validate → Rollback Plan → Deploy → Monitor |
| `onboard-developer` | 6 | Codebase overview → Dev setup → Architecture → Standards → First task → Mentorship |
| `performance-optimization` | 7 | Profile → Identify → Analyze → Optimize → Benchmark → Validate → Document |
| `refactor` | 6 | Analyze → Plan → Test baseline → Refactor → Verify → Document |
| `security-audit` | 7 | Threat model → Dependency scan → Code review → Auth/Authz → Data → Infra → Report |
| `write-docs` | 6 | Audit existing → Architecture → API reference → Guides → Examples → Review |

## Recipe Structure

Each recipe JSON contains:

```json
{
  "name": "Code Review",
  "description": "Systematic code review workflow...",
  "steps": [
    {
      "name": "Understand the Changes",
      "description": "Read the PR description, related issue/ticket...",
      "signal_mode": "ANALYZE",
      "tools_needed": ["file_read", "shell_execute"],
      "acceptance_criteria": "Clear understanding of the change purpose..."
    }
  ]
}
```

### Validation Rules

At load time, recipe JSON is validated for:
- Required top-level fields: `name`, `description`, `steps`
- `steps` must be a non-empty array of objects
- Each step must have `name` and `description` fields
- Optional step fields: `signal_mode` (defaults to `"ANALYZE"`), `tools_needed` (defaults to `[]`), `acceptance_criteria` (defaults to `""`)

### Code Review Steps Detail

1. **Understand the Changes** [ANALYZE] — Read PR, diff, understand purpose
2. **Check Correctness** [ANALYZE] — Review logic, edge cases, error handling
3. **Security Audit** [ANALYZE] — Check for vulnerabilities, secrets, injection
4. **Performance Review** [ANALYZE] — N+1 queries, missing indexes, blocking ops
5. **Provide Feedback** [ASSIST] — Compile findings, categorize (CRITICAL/MAJOR/MINOR)

## Resolution Paths

Recipes are resolved in this order:

1. `~/.daemon/recipes/` — User custom recipes
2. `.daemon/recipes/` — Project-local recipes  
3. `priv/recipes/` — Built-in recipes (12 canonical recipes)
4. `examples/workflows/` — Fallback (5 original recipes)

## TUI Commands

```
/recipe              # List all available recipes
/recipe code-review  # Run the code review workflow
/recipe-create NAME  # Create a new custom recipe
```

## Architecture — `new_session_prompt` Flow

When a user runs `/recipe <slug>`, the system:

1. **Backend** (`dev.ex`): Loads recipe, returns `{:new_session_prompt, prompt}` with a trimmed ~50-token prompt
2. **HTTP mapping** (`tool_routes.ex`): Maps to `{"new_session_prompt", text, ""}` in JSON response
3. **TUI** (`handle_actions.rs`): Stores prompt in `pending_prompt`, calls `create_session()` (15s timeout)
4. **SessionCreated** (`handle_backend.rs`): Clears chat, resets context warning, calls `start_sse()` to reconnect SSE to new session
5. **SseConnected** (`handle_backend.rs`): Drains `pending_prompt` → calls `submit_prompt()` → agent starts executing

**Safeguards:**
- `pending_prompt` bridges the async gap between session creation and SSE readiness
- 15-second timeout on `create_session()` — fires `SessionCreated(Err)` if backend is unreachable
- On `SessionCreated(Err)`, `pending_prompt` is drained and user sees "Recipe aborted" toast
- `context_warn_shown` one-shot flag prevents warning toast spam at ≥70% context
- `new_session_prompt` arm returns early — avoids premature Idle transition

## Known Issues (Resolved)

| Issue | Status | Resolution |
|-------|--------|------------|
| ~~TUI crashes on launch~~ | ✅ Fixed | Binary rebuilt after code changes |
| ~~Recipes in examples/ not priv/~~ | ✅ Fixed | 12 canonical recipes now in `priv/recipes/` |
| ~~SSE dropped tokens after /recipe~~ | ✅ Fixed | `start_sse()` called in `SessionCreated`, prompt drained in `SseConnected` |
| ~~Context saturation (70%+)~~ | ✅ Fixed | Fresh session per recipe, context warning toast |
| ~~Idle transition bug~~ | ✅ Fixed | `new_session_prompt` arm returns early |

## Remaining Gaps

| Item | Severity | Notes |
|------|----------|-------|
| No automated tests for `new_session_prompt` kind | Medium | Backend mapping + TUI handler need test coverage |
| No retry on `Recipe.run()` step failure | Low | Step failure aborts entire recipe |
| No progress indicator between steps | Low | User sees agent working but no step-level progress bar |

## Files

- **Module:** `lib/daemon/recipes/recipe.ex`
- **Recipes:** `priv/recipes/*.json` (12 files)
- **Fallback:** `examples/workflows/*.json` (5 files)
- **Commands:** `lib/daemon/commands/dev.ex`
- **HTTP mapping:** `lib/daemon/channels/http/api/tool_routes.ex`
- **TUI handlers:** `priv/rust/tui/src/app/handle_actions.rs`, `handle_backend.rs`, `mod.rs`

## Dependencies

- Works with `--no-start` (no server needed for list/load)
- `Recipe.run()` requires full app (agent loop, tools registry)
- TUI recipe flow requires backend on `localhost:8089` + SSE connection
