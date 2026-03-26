# Escalation Paths

## Overview

This document describes how to report issues, request features, disclose
security vulnerabilities, and contribute code to Daemon. Using the right channel
ensures the fastest response and appropriate handling.

---

## Bug Reports

**Channel**: GitHub Issues

Use GitHub Issues for all bug reports. A good bug report includes:

- Daemon version (`cat VERSION` or `bin/daemon version`)
- Operating system and architecture
- Elixir and OTP versions (`elixir --version`)
- Steps to reproduce (minimum reproduction case if possible)
- Expected behavior
- Actual behavior
- Relevant log output (with sensitive data redacted)

**Triage SLA**: The MIOSA team aims to triage new issues within 5 business
days. Triage means assigning a severity label and an initial response, not
necessarily a fix.

**Severity labels**:

| Label | Definition |
|---|---|
| `critical` | Data loss, crash on startup, security vulnerability |
| `high` | Core agent functionality broken, no workaround |
| `medium` | Feature degraded, workaround exists |
| `low` | Minor issue, cosmetic, edge case |
| `enhancement` | Not a bug; improvement request |

---

## Security Vulnerabilities

**Channel**: Responsible disclosure via private contact

Security vulnerabilities must NOT be reported via public GitHub Issues.
Public disclosure of an unpatched vulnerability puts all Daemon users at risk.

To report a security vulnerability:

1. Email the MIOSA team directly (contact available on the GitHub organization
   profile) with subject line: `[DAEMON SECURITY] <brief description>`
2. Include a description of the vulnerability, steps to reproduce, and your
   assessment of severity
3. Allow 14 days for an initial response and coordinated disclosure timeline

The MIOSA team will:
- Acknowledge receipt within 3 business days
- Provide an estimated fix timeline within 7 business days
- Credit the reporter in the security advisory unless anonymity is requested

**Scope of security concerns**:
- Remote code execution via agent tool calls or LLM output
- Prompt injection that bypasses guardrails
- Credential or secret exposure via Vault, environment variables, or logs
- Authorization bypass on HTTP API endpoints
- Denial of service via resource exhaustion (token budget bypass, etc.)

---

## Feature Requests

**Channel**: GitHub Discussions

Feature requests should be opened as GitHub Discussions (not Issues). This
allows community discussion before the MIOSA team evaluates implementation.

A good feature request includes:
- The problem you are trying to solve (not just the proposed solution)
- Your current workaround (if any)
- An assessment of how broadly useful this would be

Feature requests that affect the supervision tree structure, public API
surface, or shim layer will require an ADR before implementation begins.

**Skill contributions** (editing `SKILL.md`) are the fastest way to change
agent behavior and do not require a feature request discussion.

---

## Code Contributions

**Channel**: GitHub Pull Requests

The contribution workflow:

1. Open a GitHub Discussion or comment on an existing Issue to align on the
   approach before writing code (for non-trivial changes)
2. Fork the repository
3. Create a branch from `main`:
   ```
   git checkout -b feature/my-feature
   ```
4. Write the implementation with tests
5. Verify locally:
   ```bash
   mix test
   MIX_ENV=prod mix release daemon
   ```
6. Update the changelog (`docs/operations/changelog.md`)
7. Open a pull request against `main` with a clear description of the change
   and a link to the relevant Issue or Discussion

**Review requirements**:
- Tests must pass
- New public API surface must be documented
- Architectural changes require an ADR
- The MIOSA team will provide a review within 10 business days

---

## Documentation Contributions

Documentation contributions follow the same pull request workflow as code
contributions. Documentation PRs are generally reviewed faster than code PRs.

Scope of accepted documentation contributions:
- Fixing factual errors
- Improving clarity or completeness
- Adding missing examples
- Updating outdated information

Do not add emojis to documentation files. Follow the professional tone
established in the existing docs.

---

## Asking for Help

**Channel**: GitHub Discussions (Q&A category)

For questions about how Daemon works, how to configure it, or how to extend it,
open a GitHub Discussion in the Q&A category. Do not use GitHub Issues for
questions — Issues are reserved for confirmed bugs.

Community members are encouraged to answer questions in Discussions.

---

## Summary

| Situation | Channel |
|---|---|
| Bug report | GitHub Issues |
| Security vulnerability | Private email (responsible disclosure) |
| Feature request | GitHub Discussions |
| Question / help | GitHub Discussions (Q&A) |
| Code contribution | GitHub Pull Request |
| Documentation fix | GitHub Pull Request |
| Skill / SKILL.md contribution | GitHub Pull Request |
| Architectural change proposal | GitHub Discussion + ADR |
