# Local Development

Audience: developers setting up Daemon for active development on a local machine.

---

## Initial Setup

```sh
git clone https://github.com/Miosa-osa/OSA.git
cd Daemon
mix setup
```

`mix setup` runs `deps.get`, `ecto.setup`, and `compile`. Run it once after
cloning and again after pulling changes that add new dependencies or migrations.

---

## Running Daemon

### CLI mode (primary development interface)

```sh
bin/osa
```

Or directly via Mix:

```sh
mix chat
```

Both start the full OTP application, open the CLI chat interface, and listen on
port 8089 for HTTP API requests.

### IEx mode (for debugging and exploration)

```sh
iex -S mix
```

This starts the application inside an interactive Elixir shell. All modules are
available, and you can call functions, inspect state, and recompile on the fly.

### HTTP API mode (headless)

```sh
bin/daemon serve
```

Starts the application without the CLI interface. Useful when developing
against the HTTP API or SSE event stream.

---

## Dev Mode

Daemon supports a development mode that changes defaults for local work:

```sh
bin/daemon --dev
```

In dev mode:
- HTTP server listens on port 19001 (avoids collisions with production port 8089)
- Debug logging is enabled by default
- Budget limits are raised to avoid blocking experimental tool chains

Set the dev port manually:

```sh
DAEMON_HTTP_PORT=19001 bin/osa
```

---

## Hot Reload

### Elixir code

Elixir modules can be recompiled without restarting the application:

```sh
# In IEx
recompile()
```

`recompile/0` recompiles all changed modules. The running OTP processes
continue; the new module code is loaded and used on the next call.

For a single module:

```elixir
:code.purge(Daemon.Agent.Hooks)
r(Daemon.Agent.Hooks)   # IEx helper
```

### Soul and skill files

Reload `~/.daemon/` files (soul, skills, commands) without restarting:

```
/reload
```

Or from IEx:

```elixir
Daemon.Soul.load()
Daemon.PromptLoader.load()
Daemon.Tools.Registry.reload_skills()
```

---

## Desktop App (Tauri)

The desktop app is a Tauri application with a Svelte frontend.
It connects to the Daemon HTTP API on port 8089.

### Prerequisites

- Node.js 18 LTS or later
- Rust stable (via `rustup`)
- Tauri CLI: `cargo install tauri-cli`

### Run in development

```sh
cd desktop
npm install
npm run tauri:dev
```

This starts:
- Vite dev server for the Svelte frontend (with HMR)
- The Tauri application shell pointing to the Vite server

The desktop app expects Daemon to be running separately (`bin/osa`).
It does not start the Elixir backend itself.

### Frontend hot reload

The Svelte frontend uses Vite. Any change to `.svelte`, `.ts`, or `.css` files
under `desktop/src/` triggers immediate hot module replacement — no page reload
needed.

### Build for local testing

```sh
cd desktop
npm run tauri:build
```

The compiled binary is placed in `desktop/src-tauri/target/release/`.

---

## Database

Daemon uses SQLite for the local agent store (`osa.db` by default).

```sh
# Reset the database (drops and recreates)
mix ecto.reset

# Run pending migrations only
mix ecto.migrate

# Roll back the last migration
mix ecto.rollback

# Open the database directly
sqlite3 osa.db
```

The database file path is configured by the `DATABASE_PATH` environment
variable or defaults to the project root.

### Platform PostgreSQL (optional)

If `DATABASE_URL` is set, Daemon starts a second Ecto repo (`Platform.Repo`)
backed by PostgreSQL. This enables multi-tenant features.

```sh
export DATABASE_URL=postgresql://user:pass@localhost/osa_dev
mix ecto.migrate
```

---

## Environment File

For local development, create a `.env` file in the project root:

```sh
# .env (not committed to source control)
ANTHROPIC_API_KEY=sk-ant-...
DAEMON_DEFAULT_PROVIDER=anthropic
DAEMON_MODEL=claude-haiku-4-5
DAEMON_HTTP_PORT=8089
DAEMON_DAILY_BUDGET_USD=10.0
```

The `.env` file is loaded at startup by `config/runtime.exs`. It is listed in
`.gitignore` and must never be committed.

---

## Useful Mix Tasks

| Task | Description |
|------|-------------|
| `mix setup` | deps.get + ecto.setup + compile |
| `mix chat` | Start in CLI mode |
| `mix test` | Run unit tests |
| `mix test --include integration` | Run all tests including integration |
| `mix test --cover` | Run tests with coverage report |
| `mix ecto.reset` | Drop and recreate the database |
| `mix deps.update --all` | Update all dependencies |
| `mix compile --warnings-as-errors` | Strict compilation check |

---

## Common Development Workflows

### Add a new tool

1. Create `lib/daemon/tools/builtins/my_tool.ex`
2. Implement `Daemon.Tools.Behaviour`
3. Register in `Supervisors.Infrastructure` init or call `Tools.Registry.register/1`
4. Write tests in `test/daemon/tools/my_tool_test.exs`
5. Run `mix test` to verify

### Add a new channel adapter

1. Create `lib/daemon/channels/my_channel.ex`
2. Implement `Daemon.Channels.Behaviour`
3. Add to `Channels.Starter` or call `DynamicSupervisor.start_child/2`
4. Add config key and env var to `config/runtime.exs`

### Add a new configuration key

1. Add env var read to `config/runtime.exs`
2. Add compile-time default to `config/config.exs`
3. Read with `Application.get_env(:daemon, :my_key, default)`

---

## Related

- [Getting Started](../how-to/getting-started.md) — first-time setup
- [Project Structure](./project-structure.md) — directory layout and conventions
- [Coding Standards](./coding-standards.md) — style guide
