---
name: code-generation
description: "Generate complete, functional codebases from natural language requirements. Scaffolds projects, writes real implementation code, initializes toolchains, and verifies the output compiles and runs."
tools: [file_write, file_read, file_edit, file_glob, shell_execute, dir_list, memory_save]
trigger: generate code|scaffold|create project|new app|code gen|build app|create api|generate api|generate frontend|generate backend|generate service|scaffold api|scaffold app
priority: 2
dynamic: false
created: "2026-03-02"
---

# Code Generation Skill

Generate complete, production-ready codebases from natural language descriptions. This skill turns requirements into real, runnable code -- not templates or pseudocode.

## Activation Conditions

This skill activates when:
- Keywords detected: generate, scaffold, create project, new app, code gen, build app, create api
- User describes a feature, app, or service they want built
- User provides a PRD, spec, or requirements document

## Core Principles

1. **Real code only** -- every file must contain functional, idiomatic code
2. **Compile-first** -- output must compile/parse without errors before delivery
3. **Convention over configuration** -- follow the target ecosystem's standard project layout
4. **Incremental creation** -- plan the file tree, then create files in dependency order
5. **Verify before done** -- run the build/check command and show evidence

## Workflow

### Phase 1: Requirements Analysis

Before writing any code, extract and confirm:

```
1. LANGUAGE & RUNTIME
   - Primary language (Go, TypeScript, Python, Elixir, Rust, etc.)
   - Runtime version constraints
   - Package manager (npm, pnpm, mix, cargo, go modules, pip/uv)

2. FRAMEWORK & LIBRARIES
   - Web framework (SvelteKit, Next.js, Phoenix, Chi, Gin, FastAPI, etc.)
   - ORM / database driver (Prisma, Ecto, sqlc, GORM, Drizzle)
   - UI library (Tailwind, shadcn, Bits UI)
   - Testing framework (Vitest, Jest, ExUnit, go test, pytest)

3. FUNCTIONALITY
   - Core features (list each with acceptance criteria)
   - Data model / entities
   - API surface (endpoints, events, commands)
   - Authentication / authorization requirements
   - External integrations

4. CONSTRAINTS
   - Target directory for output
   - Existing codebase to integrate with (or greenfield)
   - Environment requirements (Docker, database, Redis, etc.)
```

If language or framework is completely unspecified, make a reasonable default choice and state it clearly. Proceed immediately without asking for approval.

### Phase 2: Architecture Planning

Design the project structure before creating any files.

```
Actions:
1. Search memory for relevant patterns:
   - memory_save key: "codegen:{language}:{framework}" if found
   - Reuse proven layouts from past generations

2. Define the file tree (output it for user review):
   project-name/
   +-- README.md
   +-- <config files>
   +-- src/ or lib/ or internal/
   |   +-- <module structure>
   +-- test/ or *_test.go or *.test.ts
   +-- <infra files if needed>

3. Define creation order (dependencies first):
   Wave 1: Config files (package.json, go.mod, mix.exs, etc.)
   Wave 2: Data models / types / schemas
   Wave 3: Core business logic / services
   Wave 4: API layer / handlers / routes
   Wave 5: Tests
   Wave 6: Infrastructure (Dockerfile, docker-compose, CI)
   Wave 7: Documentation (README)

4. Output the planned file tree as a brief summary, then proceed immediately to Phase 3
```

### Phase 3: Project Initialization

Initialize the project using the ecosystem's standard toolchain.

```
By Language:

Go:
  shell_execute: go mod init <module-path>
  shell_execute: go mod tidy (after writing imports)

Node.js / TypeScript:
  shell_execute: npm init -y
  shell_execute: npm install <dependencies>
  shell_execute: npm install -D <dev-dependencies>
  Then: write tsconfig.json, .eslintrc, etc.

SvelteKit:
  shell_execute: npm create svelte@latest <name> -- --template skeleton
  shell_execute: cd <name> && npm install

Elixir / Phoenix:
  shell_execute: mix phx.new <name> --no-ecto (or with ecto)
  shell_execute: cd <name> && mix deps.get

Python:
  shell_execute: python -m venv .venv
  file_write: requirements.txt or pyproject.toml
  shell_execute: pip install -r requirements.txt

Rust:
  shell_execute: cargo init <name>
  Then: edit Cargo.toml with dependencies
```

If the user wants to add code to an existing project, skip initialization. Use `dir_list` and `file_glob` to understand the existing structure first.

### Phase 4: Code Generation

Create files in dependency order using `file_write`. Every file must contain complete, functional code.

#### 4.1 Data Layer

```
Create in order:
1. Database schema / migrations
2. Models / types / structs
3. Repository / query layer
4. Seed data (if applicable)

Quality rules:
- Use parameterized queries (never string interpolation for SQL)
- Include proper indexes in migrations
- Define all types explicitly (no `any` in TypeScript, no interface{} in Go)
- Add validation constraints at the model level
```

#### 4.2 Business Logic

```
Create in order:
1. Service interfaces / contracts
2. Service implementations
3. Error types and handling
4. Utility functions specific to the domain

Quality rules:
- Single responsibility per service
- Error handling at every boundary (no silent failures)
- Context propagation (Go: context.Context, Elixir: process metadata)
- Input validation before processing
```

#### 4.3 API Layer

```
Create in order:
1. Route definitions / router setup
2. Request/response types (DTOs)
3. Handlers / controllers
4. Middleware (auth, logging, CORS, rate limiting)

Quality rules:
- Consistent response format: { data, meta } or { error: { code, message } }
- Proper HTTP status codes (201 for create, 204 for delete, etc.)
- Input validation using schema libraries (Zod, validator, etc.)
- No business logic in handlers -- delegate to services
```

#### 4.4 Frontend (if applicable)

```
Create in order:
1. Layout components
2. Shared UI components
3. Page components / routes
4. State management (stores, context)
5. API client / data fetching

Quality rules:
- Semantic HTML, accessible markup
- Responsive by default
- Loading and error states for async operations
- Type-safe API calls
```

#### 4.5 Tests

```
Create alongside or immediately after implementation:
1. Unit tests for business logic (services, utilities)
2. Integration tests for API endpoints
3. Component tests for UI (if frontend)

Quality rules:
- Test behavior, not implementation details
- Cover happy path + at least 2 edge cases per function
- Use descriptive test names: "should [behavior] when [condition]"
- Mock external dependencies, not internal modules
```

### Phase 5: Wiring & Configuration

```
After all source files exist:
1. Entry point (main.go, index.ts, app.py, application.ex)
   - Wire dependencies together
   - Configure middleware
   - Start the server

2. Environment configuration
   - .env.example with all required variables (no real secrets)
   - Config loader that reads from environment

3. Infrastructure (if requested)
   - Dockerfile (multi-stage build)
   - docker-compose.yml (with database, Redis, etc.)
   - .dockerignore

4. Developer tooling
   - .gitignore (language-appropriate)
   - Makefile or package.json scripts for common tasks
   - Linter/formatter configuration
```

### Phase 6: Verification

This phase is mandatory. Never skip it.

```
Verification steps by language:

Go:
  shell_execute: cd <project> && go build ./...
  shell_execute: cd <project> && go vet ./...
  shell_execute: cd <project> && go test ./... -count=1

TypeScript / Node.js:
  shell_execute: cd <project> && npx tsc --noEmit
  shell_execute: cd <project> && npm test

SvelteKit:
  shell_execute: cd <project> && npm run check
  shell_execute: cd <project> && npm run build

Elixir:
  shell_execute: cd <project> && mix compile --warnings-as-errors
  shell_execute: cd <project> && mix test

Python:
  shell_execute: cd <project> && python -m py_compile <main_file>
  shell_execute: cd <project> && python -m pytest

Rust:
  shell_execute: cd <project> && cargo check
  shell_execute: cd <project> && cargo test
```

If verification fails:
1. Read the error output carefully
2. Use `file_edit` to fix the issue
3. Re-run verification
4. Repeat until clean

### Phase 7: Documentation & Handoff

```
1. Generate README.md with:
   - Project description
   - Prerequisites
   - Setup instructions (step by step)
   - Available commands (dev, build, test, lint)
   - API documentation (if applicable)
   - Environment variables reference

2. Save patterns to memory:
   memory_save: "codegen:{language}:{framework}:layout" -> file tree
   memory_save: "codegen:{language}:{framework}:config" -> key config decisions

3. Present summary to user:
   - Files created (count and list)
   - Verification results
   - How to run the project
   - Suggested next steps
```

## Language-Specific Templates

### Go REST API

```
project/
+-- cmd/server/main.go          # Entry point, wire dependencies
+-- internal/
|   +-- config/config.go        # Environment-based configuration
|   +-- handler/                # HTTP handlers (one file per resource)
|   +-- service/                # Business logic
|   +-- repository/             # Database access
|   +-- model/                  # Domain types
|   +-- middleware/              # Auth, logging, recovery, CORS
+-- pkg/                        # Shared utilities (if any)
+-- migrations/                 # SQL migration files
+-- go.mod
+-- go.sum
+-- Makefile
+-- Dockerfile
+-- .env.example
+-- README.md
```

### SvelteKit Application

```
project/
+-- src/
|   +-- routes/
|   |   +-- +layout.svelte      # Root layout
|   |   +-- +page.svelte        # Home page
|   |   +-- api/                # API routes (+server.ts)
|   |   +-- [feature]/          # Feature routes
|   +-- lib/
|   |   +-- components/         # Reusable components
|   |   |   +-- ui/             # Base UI components
|   |   +-- stores/             # Svelte stores
|   |   +-- utils/              # Utility functions
|   |   +-- types/              # TypeScript types
|   +-- app.d.ts
|   +-- app.css
+-- static/
+-- tests/
+-- svelte.config.js
+-- vite.config.ts
+-- tsconfig.json
+-- tailwind.config.ts
+-- package.json
+-- .env.example
+-- README.md
```

### Elixir Phoenix API

```
project/
+-- lib/
|   +-- project/                # Business domain
|   |   +-- accounts/           # Context: accounts
|   |   +-- catalog/            # Context: catalog
|   +-- project_web/            # Web layer
|   |   +-- controllers/
|   |   +-- views/ or json/
|   |   +-- router.ex
|   |   +-- endpoint.ex
+-- priv/
|   +-- repo/migrations/
+-- test/
|   +-- project/
|   +-- project_web/
+-- config/
+-- mix.exs
+-- .env.example
+-- README.md
```

### Python FastAPI

```
project/
+-- app/
|   +-- __init__.py
|   +-- main.py                 # FastAPI app, mount routers
|   +-- config.py               # Settings from environment
|   +-- models/                 # SQLAlchemy / Pydantic models
|   +-- routers/                # API route handlers
|   +-- services/               # Business logic
|   +-- repositories/           # Database access
|   +-- schemas/                # Request/response schemas
+-- tests/
+-- alembic/                    # Migrations (if using Alembic)
+-- requirements.txt
+-- Dockerfile
+-- .env.example
+-- README.md
```

## Security Guardrails

Apply automatically to all generated code:

1. **No hardcoded secrets** -- always read from environment variables
2. **Parameterized queries** -- never interpolate user input into SQL
3. **Input validation** -- validate all external input at API boundaries
4. **Error handling** -- never expose stack traces or internal details to clients
5. **Secure defaults** -- CORS restricted, HTTPS-ready, secure cookie flags
6. **Dependencies** -- use well-maintained packages, pin versions
7. **Authentication** -- if auth is required, use industry-standard patterns (JWT, sessions)
8. **.gitignore** -- always exclude .env, secrets, build artifacts, node_modules

## Error Recovery

If generation fails at any phase:

| Phase | Recovery Strategy |
|-------|-------------------|
| Initialization | Check if toolchain is installed, suggest install command |
| Code generation | Read error from file_write, fix path or content |
| Dependency install | Check network, try alternative registry, pin versions |
| Compilation | Read error output, fix the specific file, re-verify |
| Tests fail | Fix the failing test or implementation, re-run |

Never leave the project in a broken state. If you cannot fix the issue, clearly report what failed and why.

## Integration with Other Skills

| Skill | Integration Point |
|-------|-------------------|
| tdd-enforcer | Write tests alongside implementation in Phase 4 |
| security-auditor | Apply security guardrails during generation |
| coding-workflow | Code generation is the IMPLEMENT phase |
| verification-before-completion | Phase 6 verification is mandatory |
| memory-sync | Phase 7 saves patterns for future generations |

## Output Summary Format

After completing generation, present:

```
CODE GENERATION COMPLETE
========================
Project: {name}
Language: {language} | Framework: {framework}
Directory: {path}

Files Created: {count}
  - {category}: {file_list}

Verification:
  Build:  PASS
  Tests:  {pass_count} passed, {fail_count} failed
  Lint:   PASS

Run the project:
  cd {path}
  {run_command}

Next Steps:
  1. Review generated code
  2. Configure .env with real values
  3. {context-specific suggestion}
```
