# OSA — Optimal System Agent

## Quick Reference

### Development Commands
```bash
# Interactive chat (default)
mix chat

# Run tests
mix test

# Setup database
mix ecto.setup

# Build release
mix release

# Start CLI with subcommands
./bin/osagent chat      # interactive mode
./bin/osagent setup     # configure provider
./bin/osagent version   # print version
./bin/osagent serve     # HTTP API mode
./bin/osagent doctor    # health check
```

### Project Type
- **Language**: Elixir/OTP 1.17
- **Architecture**: Signal Theory-based AI agent
- **Database**: SQLite3 (local), PostgreSQL (platform multi-tenant)
- **Communication**: HTTP (Bandit), Webhooks, gRPC (VAS-Swarm Kernel)

### Key Features
- Multi-channel support: CLI, HTTP API, Telegram, Discord, Slack, Email
- Signal classification: (Mode, Genre, Type, Format, Weight)
- Persistent memory with vault system
- Sub-agent orchestration (24 agents across 3 tiers)
- Skill management (create reusable workflows)
- Computer use (desktop automation via screenshots + accessibility trees)
- MCP server integration

### Dependencies
- **req**: HTTP client for LLM APIs
- **jason**: JSON parsing
- **ecto_sql**: Database wrapper
- **phoenix_pubsub**: Internal event fan-out
- **bandit**: HTTP server
- **goldrush**: Event routing (BEAM speed)

### Release Process
1. Compile Go tokenizer: `priv/go/tokenizer/osa-tokenizer`
2. Build Elixir release: `mix release`
3. Wrapper installs: `bin/osagent` with subcommands

### Environment
- Config: `config/config.exs`
- Runtime env vars for provider selection
- Optional: RabbitMQ (AMQP), gRPC for VAS-Swarm integration
