# Team Ownership

## Project Authors

OSA (Optimal System Agent) is built by **Roberto H. Luna** and the **MIOSA team**.

The project is open-source and welcomes community contributions. The MIOSA team
maintains final review authority over architectural decisions, public API
changes, and the supervision tree structure.

---

## License

OSA is licensed under the **Apache License 2.0**.

```
Copyright 2024 Roberto H. Luna / MIOSA

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0
```

The full license text is in `/LICENSE`.

---

## Contribution Model

OSA prioritizes **skill contributions over code contributions**.

### SKILL.md as the Preferred Contribution Path

OSA agents learn from experience files. The most impactful way to contribute
to the project's intelligence is by editing `SKILL.md` — a structured YAML
file that describes task patterns, tools, and resolution strategies. Skill
contributions:

- Do not require programming knowledge
- Do not require understanding the supervision tree
- Have immediate visible effect on agent behavior
- Are reviewed faster than code PRs because they do not require runtime testing

See `CONTRIBUTING.md` for the SKILL.md contribution format and review process.

### Code Contributions

Code contributions are welcome and follow the process in `CONTRIBUTING.md`:

1. Fork the repository on GitHub
2. Create a branch from `main`
3. Implement the change with tests
4. Open a pull request against `main`
5. Address review feedback from MIOSA team members

Pull requests must:
- Pass all tests (`mix test`)
- Follow the TypeScript/Elixir conventions in `docs/development/`
- Include a changelog entry
- Include an ADR for architectural changes

### Review Authority

The MIOSA team holds review authority over:
- Changes to `lib/optimal_system_agent/supervisors/`
- Changes to `lib/optimal_system_agent/application.ex`
- Changes to `lib/miosa/shims.ex`
- New ADRs and changes to existing ADRs
- Changes to the HTTP API surface (`lib/optimal_system_agent/channels/http/`)
- Changes to public hook signatures (`lib/optimal_system_agent/agent/hooks.ex`)

---

## Governance

OSA does not currently operate under a formal governance structure (foundation,
TSC, steering committee). Decisions are made by the MIOSA team with community
input via GitHub Discussions.

Significant architectural changes require an ADR (see
`docs/foundation-core/governance/architectural-decisions/`) before implementation
begins.

---

## Contact

| Channel | Use |
|---|---|
| GitHub Issues | Bug reports, feature requests |
| GitHub Discussions | Design discussions, questions, RFCs |
| GitHub Pull Requests | Code and documentation contributions |
| `CONTRIBUTING.md` | Contribution process documentation |

Security vulnerabilities should not be reported via public GitHub Issues.
See `docs/foundation-core/ownership/escalation-paths.md` for the responsible
disclosure process.
