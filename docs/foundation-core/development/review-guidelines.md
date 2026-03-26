# Review Guidelines

Audience: PR authors preparing submissions and reviewers evaluating them.

---

## Goal

Code review exists to catch defects before they reach the main branch, share
knowledge across the team, and maintain a consistent codebase. Reviews should
be completed within one business day. Authors are responsible for keeping PRs
small and reviewable (under 400 lines changed).

---

## PR Checklist (Author)

Before opening a PR:

- [ ] `mix format` has been run
- [ ] `mix compile --warnings-as-errors` passes with zero warnings
- [ ] `mix test` passes (all unit tests green)
- [ ] Integration tests pass if the change touches channels, agent loop, or
      supervisor tree: `mix test --include integration`
- [ ] New public functions have `@doc` and `@spec`
- [ ] New modules have `@moduledoc`
- [ ] No hardcoded secrets, API keys, or test credentials in source
- [ ] No `IO.inspect` or `dbg` left in production code paths
- [ ] Migration files present if schema changed
- [ ] Documentation updated if behaviour changed

---

## Review Checklist

### Correctness

- [ ] Logic is correct for the stated purpose
- [ ] Edge cases are handled (empty input, nil, boundary values)
- [ ] Error paths return `{:error, reason}` and are not silently swallowed
- [ ] Async operations have failure handling
- [ ] Pattern matches are exhaustive or have a catch-all clause
- [ ] No obvious race conditions in concurrent code

### Security

- [ ] No hardcoded secrets, passwords, or API keys in any file
- [ ] User-supplied input is validated before use (especially file paths and
      shell commands)
- [ ] Tool `execute/1` functions do not expose the file system beyond
      `DAEMON_WORKING_DIR` without explicit permission tier enforcement
- [ ] No new HTTP endpoints bypass the authentication middleware when
      `require_auth` is enabled
- [ ] Sensitive data (API keys, message content, PII) is not passed to
      `Logger`

### Performance

- [ ] No N+1 patterns (database queries or LLM calls inside loops)
- [ ] ETS reads are used for hot-path lookups, not GenServer calls
- [ ] Large collections use `Task.async_stream` for parallelism, not `Enum.map`
- [ ] No unnecessary `Process.sleep/1` in production code
- [ ] Context compaction thresholds are not hardcoded (read via
      `Application.get_env`)

### OTP Patterns

- [ ] New processes are supervised — no bare `spawn/1` or `spawn_link/1`
- [ ] GenServer `init/1` does not make blocking calls (HTTP, file I/O)
  — use `{:continue, :init}` for deferred initialization
- [ ] ETS tables created in `application.ex` if they must survive process
      restarts; in `init/1` if they are owned by that GenServer
- [ ] Supervisor strategy is appropriate: `:rest_for_one` only where crash
      ordering is critical, `:one_for_one` otherwise
- [ ] DynamicSupervisor used for session-scoped or runtime-determined
      processes

### Tests

- [ ] Unit tests included for new public functions
- [ ] Edge cases covered (nil inputs, empty collections, error returns)
- [ ] No real LLM calls in tests (verified by `classifier_llm_enabled: false`
      in test config)
- [ ] `async: false` used for tests that touch named GenServers or ETS tables
- [ ] No `Process.sleep/1` in tests where an `assert_receive` with timeout
      would work

### Documentation

- [ ] `@moduledoc` present on new modules
- [ ] `@doc` and `@spec` present on new public functions
- [ ] Inline comments explain *why* non-obvious code does what it does
- [ ] If the change alters a public API or configuration key, the relevant
      doc file is updated

### Style

- [ ] Follows the [Coding Standards](./coding-standards.md)
- [ ] Function heads used instead of `case`/`cond` where applicable
- [ ] `with` used for happy-path chains
- [ ] No dead code (commented-out implementations, unreachable clauses)
- [ ] Imports organized: external libs first, then internal

---

## Review Output Format

Leave inline comments for specific issues. Use the PR-level summary for the
overall verdict:

```
## Review Summary

### Overall: APPROVED | NEEDS CHANGES | BLOCKED

### Issues Found
1. [CRITICAL] lib/path/to/file.ex:42 — API key logged in error handler
2. [MAJOR]    lib/path/to/file.ex:88 — bare spawn/1 without supervisor
3. [MINOR]    lib/path/to/file.ex:15 — missing @spec on public function

### Suggestions
- Consider using ETS for the registry lookup on line 67 — the GenServer call
  will be a bottleneck under concurrent load.

### Positive Notes
- Clean use of with for the validation chain in process_request/1
- Good test coverage of error paths
```

Severity definitions:

| Severity | Definition |
|----------|-----------|
| CRITICAL | Security vulnerability, data loss risk, or breaks production |
| MAJOR | Correctness bug, bad OTP pattern, missing tests for critical path |
| MINOR | Style, naming, missing doc, performance suggestion |

---

## Blocking vs. Non-Blocking Issues

**Block the merge** for:
- Any CRITICAL issue
- Tests failing
- Compilation warnings not resolved
- Hardcoded secrets

**Request changes** (author must address before merge) for:
- MAJOR issues
- Missing `@doc`/`@spec` on new public API
- Bare `spawn` without supervision

**Leave as suggestions** (author's discretion) for:
- MINOR style issues
- Performance suggestions where the current approach is not wrong
- Alternative designs that are equally valid

---

## Self-Review

Authors should self-review using this checklist before requesting a review.
A self-reviewed PR that already addresses obvious issues takes significantly
less reviewer time.

---

## Related

- [Coding Standards](./coding-standards.md) — the standards reviewers enforce
- [Writing Unit Tests](../how-to/testing/writing-unit-tests.md) — what test coverage looks like
- [Security](../security/) — security-specific review criteria
