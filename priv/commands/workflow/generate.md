---
name: generate
description: Generate code from natural language requirements
arguments:
  - name: requirements
    required: true
    description: "What to build: language, framework, features, and any constraints"
  - name: target
    required: false
    default: "."
    description: "Target directory for the generated project"
---

# Generate - Code from Requirements

Generate a complete, functional codebase from a natural language description.

## Usage

```
/generate "A REST API in Go with Chi for a task management system with CRUD endpoints, PostgreSQL storage, and JWT auth"

/generate "A SvelteKit app with Tailwind that displays a dashboard with charts and a sidebar navigation" --target ./frontend

/generate "A Python FastAPI microservice that processes webhook events from Stripe and stores them in PostgreSQL"

/generate "Add a notifications module to the existing Elixir Phoenix app with email and in-app channels"
```

## What Happens

1. **Analyze** your requirements to extract language, framework, features, and constraints
2. **Plan** the file tree and creation order -- present it for your approval
3. **Initialize** the project using standard toolchain (go mod init, npm create, mix new, etc.)
4. **Generate** all source files with real, functional code in dependency order
5. **Wire** the entry point, configuration, and infrastructure files
6. **Verify** the code compiles, tests pass, and linting is clean
7. **Document** with a README and save reusable patterns to memory

## Supported Stacks

| Language | Frameworks | Package Manager |
|----------|-----------|-----------------|
| Go | Chi, Gin, Echo, standard library | go modules |
| TypeScript | SvelteKit, Next.js, Express, Fastify, NestJS | npm, pnpm |
| Elixir | Phoenix, LiveView | mix |
| Python | FastAPI, Flask, Django | pip, uv, poetry |
| Rust | Actix-web, Axum, Rocket | cargo |

## Options

```
--target <path>     Directory to generate into (default: current directory)
--dry-run           Show the plan without creating files
--no-tests          Skip test generation
--no-docker         Skip Dockerfile and docker-compose
--existing          Add to an existing project (reads structure first)
```

## Tips

- Be specific about the framework you want -- "Go with Chi" is better than just "Go API"
- Mention the database if you need persistence -- "PostgreSQL", "SQLite", "Redis"
- Describe the data model -- "users, projects, and tasks with assignments"
- Mention auth requirements -- "JWT auth", "session cookies", "OAuth with Google"
- For frontend apps, mention styling -- "Tailwind", "shadcn", "CSS modules"

## Examples

### Minimal API
```
/generate "A Go REST API with Chi that serves a /health endpoint and a /api/v1/items CRUD resource backed by an in-memory store"
```

### Full-Stack Application
```
/generate "A SvelteKit app with TypeScript, Tailwind, and a Go backend API. The app manages a list of bookmarks with title, URL, tags, and notes. Include a search bar that filters bookmarks and tag-based navigation."
```

### Adding to Existing Project
```
/generate "Add a WebSocket-based real-time notification system to the existing Phoenix app. Notifications should support in-app and email channels with user preferences." --existing
```

### Microservice
```
/generate "A Python FastAPI microservice that: 1) accepts webhook events from Stripe at POST /webhooks/stripe, 2) validates the webhook signature, 3) stores events in PostgreSQL, 4) publishes to a Redis stream for downstream consumers. Include health check, structured logging, and Docker setup."
```

## Agent Dispatch

Primary: Skill `code-generation` handles the full workflow.
Support agents activated by context:
- `@backend-go` for Go projects
- `@frontend-svelte` for SvelteKit projects
- `@frontend-react` for React/Next.js projects
- `@database-specialist` for complex data modeling
- `@security-auditor` for auth-related generation
- `@test-automator` for comprehensive test suites
