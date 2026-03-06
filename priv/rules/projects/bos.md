# BusinessOS (BOS) Project Rules

When working on files in `~/Desktop/BOS` or paths containing `businessos`, `businessos-backend`,
or the Go module `github.com/rhl/businessos-backend`, apply these rules.

## Stack
- **Backend**: Go 1.24.1 + Gin + PostgreSQL + Redis + pgvector
- **Frontend**: SvelteKit + TypeScript + Tailwind CSS + Svelte 5 (runes: `$state`, `$props`, `$effect`)
- **Database access**: sqlc-generated code in `internal/database/sqlc/`
- **Go module**: `github.com/rhl/businessos-backend`

## Backend (Go) Rules

### Logging — MANDATORY
ALWAYS use `slog` for logging. NEVER use `fmt.Printf`, `fmt.Println`, or `log.Printf`.

```go
// CORRECT
slog.InfoContext(ctx, "user logged in", "user_id", userID)
slog.ErrorContext(ctx, "query failed", "error", err, "user_id", userID)

// WRONG — never do this
fmt.Printf("user logged in: %s\n", userID)
log.Printf("error: %v", err)
```

### Architecture — Handler → Service → Repository
Every feature follows this layered pattern:
```
HTTP Request → Handler (input validation, auth check)
                  ↓
             Service (business logic, orchestration)
                  ↓
             Repository / sqlc (data access)
                  ↓
             Database (PostgreSQL)
```

### Handler Pattern
```go
func (h *Handlers) GetEntity(c *gin.Context) {
    ctx := c.Request.Context()
    userID := c.GetString("user_id")

    result, err := h.entityService.GetEntity(ctx, userID)
    if err != nil {
        slog.ErrorContext(ctx, "failed to get entity", "error", err)
        c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
        return
    }

    c.JSON(http.StatusOK, result)
}
```

### Context Propagation
Pass `ctx context.Context` as the first argument through ALL function calls.
```go
// CORRECT
func (s *EntityService) GetEntity(ctx context.Context, userID string) (*Entity, error)

// WRONG
func (s *EntityService) GetEntity(userID string) (*Entity, error)
```

### Error Handling
- Never panic in HTTP handlers — return error responses
- Wrap errors with context: `fmt.Errorf("getting entity: %w", err)`
- Log at the service/handler level where context is richest

### Database Queries
Always use sqlc-generated code from `internal/database/sqlc/`. Check existing queries before writing new SQL.
```go
// Use generated query
result, err := h.queries.GetEntityByID(ctx, entityID)
```

### Route Registration
Routes are registered in `cmd/server/main.go`. Follow the existing pattern using Gin router groups.

## Frontend (SvelteKit) Rules

### Svelte 5 Runes
Use Svelte 5 rune syntax (not Svelte 4 stores where possible):
```typescript
// State
let count = $state(0);
let user = $state<User | null>(null);

// Derived
let doubled = $derived(count * 2);

// Effects
$effect(() => {
    console.log('count changed:', count);
});

// Props
let { name, onSubmit }: { name: string; onSubmit: () => void } = $props();
```

### Data Loading
Use `+page.server.ts` for server-side data loading:
```typescript
// +page.server.ts
export const load = async ({ fetch, locals }) => {
    const data = await fetch('/api/entities').then(r => r.json());
    return { entities: data };
};
```

### Mutations
Use Svelte form actions for mutations (not client-side fetch when possible):
```typescript
// +page.server.ts
export const actions = {
    create: async ({ request }) => {
        const data = await request.formData();
        // handle mutation
    }
};
```

### API Client
Use the existing API client in `frontend/src/lib/api/client.ts` for frontend fetches.

### Stores
Global state lives in `frontend/src/lib/stores/`. Check existing stores before creating new ones.

## Code Generation Quality Rules

When generating Go or TypeScript/Svelte code for BOS:

1. **Always generate complete, compilable files** — no truncation, no placeholders
2. **Import paths must be exact** — use `github.com/rhl/businessos-backend/internal/...`
3. **Match existing patterns** — read neighboring files to understand conventions before writing
4. **Include error handling** — every database call and external call must handle errors
5. **No TODO stubs** — implement the actual logic, not `// TODO: implement`

## Build Verification
After any backend change: `cd ~/Desktop/BOS/desktop/backend-go && go build ./cmd/server`
After any frontend change: `cd ~/Desktop/BOS/frontend && pnpm build` or check types with `pnpm check`
