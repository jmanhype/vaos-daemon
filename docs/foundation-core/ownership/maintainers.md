# Maintainers

OSA is developed by **Roberto H. Luna** and the **MIOSA team** under the
[miosa-osa](https://github.com/Miosa-osa) GitHub organization.

---

## Project Lead

**Roberto H. Luna** ([@robertohluna](https://github.com/robertohluna))

Roberto is the original author of OSA and the author of Signal Theory (Luna, 2026),
the theoretical framework underlying OSA's message classification system. He holds
final decision authority on:

- Architecture — supervision tree structure, event routing, provider abstraction
- Signal Theory implementation and classifier correctness
- Public API surface (HTTP API, SDK, hook signatures)
- ADR acceptance and rejection

---

## MIOSA Team

The MIOSA team consists of contributors with commit access to the
[Miosa-osa/OSA](https://github.com/Miosa-osa/OSA) repository. Team members are
identified by their GitHub account association with the `miosa-osa` organization.

Team responsibilities:
- Code review for pull requests
- Triage and prioritization of GitHub Issues
- Release tagging and changelog maintenance
- Homebrew formula updates

---

## Communication Channels

| Channel | Purpose | URL |
|---|---|---|
| GitHub Issues | Bug reports, feature requests, questions | https://github.com/Miosa-osa/OSA/issues |
| GitHub Discussions | Design discussions, RFCs, community support | https://github.com/Miosa-osa/OSA/discussions |
| GitHub Pull Requests | Code and documentation contributions | https://github.com/Miosa-osa/OSA/pulls |

There is no Slack, Discord, or mailing list at this time. GitHub is the primary
communication channel for all project activity.

### Reporting Security Vulnerabilities

Security vulnerabilities must not be reported via public GitHub Issues. Use GitHub's
private vulnerability reporting feature:
https://github.com/Miosa-osa/OSA/security/advisories/new

The MIOSA team will acknowledge receipt within 72 hours and provide a timeline for
a fix. See `docs/foundation-core/ownership/escalation-paths.md` for the full
responsible disclosure process.

---

## How to Reach the Team

**For bug reports**: Open a GitHub Issue with the `bug` label. Include the OSA
version (`mix run -e "OptimalSystemAgent.CLI.version()"`), the operating system,
and steps to reproduce.

**For feature requests**: Open a GitHub Issue with the `enhancement` label.
Describe the use case, not just the implementation. If you have implementation ideas,
include them but make the use case primary.

**For questions about the codebase**: Use GitHub Discussions. Tag your discussion
with the relevant area (e.g., `signal-theory`, `providers`, `supervision`).

**For architectural proposals**: Open a GitHub Discussion with type `RFC`. Significant
proposals should include a draft ADR in the format described in
`docs/foundation-core/governance/architectural-decisions/adr-template.md`.

**For urgent production issues**: There is no on-call support. OSA is open-source
software provided under the Apache 2.0 license with no warranty. For production
deployments requiring support, contact the MIOSA team via GitHub Discussions.

---

## Decision-Making Process

OSA does not operate under a formal governance structure (foundation, TSC, steering
committee). Decisions are made by the MIOSA team with community input.

For routine changes (bug fixes, new providers, new skills): PR review by one MIOSA
team member is sufficient.

For significant changes (supervision tree, event routing, public API, new ADR): two
MIOSA team member reviews are required, including the project lead for architectural
changes.

For breaking changes in v0.x: an ADR must be written and accepted before implementation
begins. The ADR is posted as a GitHub Discussion for community feedback before acceptance.

---

## License

OSA is licensed under the **Apache License 2.0**. By contributing to the project,
contributors agree that their contributions will be licensed under the same terms.

Copyright 2024-2026 Roberto H. Luna / MIOSA
