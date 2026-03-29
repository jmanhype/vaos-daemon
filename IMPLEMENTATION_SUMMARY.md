# Implementation Summary: /api/v1/investigate Endpoint

## Overview
Added a new `/api/v1/investigate` endpoint to the vas-swarm codebase that enables epistemic investigation with streaming results via Server-Sent Events (SSE).

## Files Created

### 1. `/lib/daemon/channels/http/api/investigate_routes.ex`
- **Purpose**: HTTP route handler for investigation endpoints
- **Key Features**:
  - `POST /` - Start a new investigation (fire-and-forget)
    - Accepts: `topic` (required), `depth` (optional, "standard" or "deep"), `steering` (optional), `metadata` (optional)
    - Returns: 202 Accepted with `investigation_id`, `status`, `topic`, `depth`
    - Runs investigation asynchronously in background Task
    - Broadcasts completion via Phoenix PubSub

  - `GET /stream/:investigation_id` - SSE stream for investigation results
    - Subscribes to investigation-specific PubSub channel
    - Sends SSE events: `connected`, `complete`, `error`, `done`
    - Includes keepalive every 60 seconds
    - Returns full investigation result in `complete` event

- **Architecture**:
  - Uses `Plug.Router` for HTTP handling
  - Phoenix PubSub for event broadcasting
  - Investigation runs in background Task
  - SSE pattern for real-time result streaming

### 2. `/test/daemon/channels/http/investigate_routes_test.exs`
- **Purpose**: Unit tests for investigate routes
- **Test Coverage**:
  - Parameter validation (missing/empty topic)
  - Valid request returns investigation_id
  - SSE connection setup

## Files Modified

### 1. `/lib/daemon/channels/http/api.ex`
**Changes**:
- Added forward directive: `forward "/investigate", to: API.InvestigateRoutes`
- Updated module documentation to include `/investigate` endpoint

**Location**: After `/receipts` forward, before catch-all route

### 2. `/lib/daemon/channels/http.ex`
No changes needed - documentation update only in api.ex

## API Usage

### Start Investigation
```bash
POST /api/v1/investigate
Content-Type: application/json
Authorization: Bearer <token>

{
  "topic": "Do vaccines cause autism?",
  "depth": "standard",  // optional, default "standard"
  "steering": "...",    // optional context
  "metadata": {...}     // optional metadata
}

Response (202):
{
  "investigation_id": "inv_abc123...",
  "status": "started",
  "topic": "Do vaccines cause autism?",
  "depth": "standard"
}
```

### Stream Results
```bash
GET /api/v1/investigate/stream/inv_abc123...
Authorization: Bearer <token>

SSE Events:
event: connected
data: {"investigation_id": "inv_abc123..."}

event: complete
data: {"investigation_id": "inv_abc123...", "status": "complete", "result": "## Investigation: ..."}

event: done
data: {}
```

## Integration Points

### Investigate Tool
- Uses `Daemon.Tools.Builtins.Investigate.execute/1`
- Returns `{:ok, result_text}` or `{:error, reason}`
- Result is a full markdown investigation report

### PubSub Channels
- Channel format: `"investigation:{investigation_id}"`
- Events: `{:investigation_complete, map}` and `{:investigation_error, map}`

### Background Processing
- Investigation runs in `Task.start(fn -> ... end)`
- Non-blocking - returns 202 immediately
- Results broadcast when complete

## Future Enhancements

### Progress Events
The SSE loop can be extended to emit progress events:
```elixir
{:investigation_progress, %{stage: "paper_search", message: "Searching Semantic Scholar..."}}
{:investigation_progress, %{stage: "llm_analysis", message: "Running FOR advocate..."}}
```

### Status Endpoint
Could add `GET /investigate/:id` to check investigation status without streaming.

## Testing

### Manual Testing
```bash
# Start investigation
curl -X POST http://localhost:8089/api/v1/investigate \
  -H "Content-Type: application/json" \
  -d '{"topic": "test claim"}'

# Stream results (use investigation_id from above)
curl -N http://localhost:8089/api/v1/investigate/stream/inv_abc123...
```

### Unit Tests
```bash
mix test test/daemon/channels/http/investigate_routes_test.exs
```

## Compliance

✅ Module namespace: All modules start with `Daemon.`
✅ Uses Plug.Router (not Phoenix)
✅ Route file created before forward added
✅ Uses full module path: `Daemon.Channels.HTTP.API.InvestigateRoutes`
✅ Follows existing SSE patterns (AgentRoutes, EventBus)
✅ Tests mirror lib structure
✅ No modifications to application.ex, supervisors/, security/, loop.ex, runtime.exs, mix.exs, mix.lock
