# Message Processing Workflow

Complete sequence from user input arriving at a channel to the agent response
returned to the channel. This covers the full path through `Agent.Loop`.

Source: `lib/daemon/agent/loop.ex` and supporting modules.

---

## Mermaid Sequence Diagram

```mermaid
sequenceDiagram
    actor User
    participant Chan as Channel<br/>(CLI / HTTP / Telegram / etc.)
    participant NoiseF as Channels.NoiseFilter
    participant SigC as Signal.Classifier
    participant Loop as Agent.Loop<br/>(GenServer)
    participant Guard as Loop.Guardrails
    participant GenreR as Loop.GenreRouter
    participant Ctx as Agent.Context
    participant Mem as Agent.Memory
    participant LLM as Loop.LLMClient
    participant Prov as Providers.Registry
    participant ToolEx as Loop.ToolExecutor
    participant Tools as Tools.Registry
    participant Hooks as Agent.Hooks
    participant Bus as Events.Bus

    User->>Chan: sends message

    Chan->>SigC: classify_fast(message, channel)
    SigC-->>Chan: signal{mode, genre, type, format, weight}
    Chan->>SigC: classify_async(message, channel, session_id)
    Note over SigC: fire-and-forget Task<br/>enriches signal via LLM asynchronously

    Chan->>Bus: emit(:user_message, payload)
    Chan->>Loop: process_message(session_id, message, signal, opts)

    Loop->>Guard: prompt_injection?(message)
    Guard-->>Loop: false (or blocks with refusal)

    Loop->>NoiseF: check(message, signal)
    alt weight < 0.15 or greeting pattern
        NoiseF-->>Loop: {:filtered, :noise}
        Loop->>Chan: (no response for pure noise)
    else signal passes noise filter
        NoiseF-->>Loop: {:ok, message}
    end

    Loop->>Mem: append(:user, message, session_id)
    Note over Mem: persists to JSONL + SQLite (SQLiteBridge)

    Loop->>GenreR: route_by_genre(signal.genre, message, state)
    alt genre == :inform
        GenreR-->>Loop: {:respond, "Got it — save to memory?"}
        Loop->>Chan: deliver response (skip LLM)
    else genre == :express
        GenreR-->>Loop: {:respond, empathy_response}
        Loop->>Chan: deliver response (skip LLM)
    else genre == :direct or :decide or :commit
        GenreR-->>Loop: :execute_tools

        Loop->>Ctx: build_context(session_id, signal, state)
        Ctx->>Mem: load_session_messages(session_id)
        Mem-->>Ctx: recent messages (token-budgeted)
        Ctx->>Mem: inject_long_term_memory(session_id)
        Ctx-->>Loop: messages[] with system prompt + memory + context

        alt signal.weight < 0.20 (tool_weight_threshold)
            Note over Loop: Low-signal input — no tools passed to LLM
        else weight >= 0.20
            Note over Loop: Full tool list included in LLM call
        end

        loop ReAct loop (max 30 iterations)
            Loop->>LLM: llm_chat_stream(state, messages, opts)
            LLM->>Prov: chat_stream(messages, callback, opts)
            Note over Prov: routes to configured provider<br/>streams tokens → Bus(:system_event)
            Prov-->>LLM: {:done, result} | {:error, reason}
            LLM-->>Loop: {:ok, result} | {:error, reason}

            alt result has no tool_calls
                Note over Loop: Final response — exit loop
                Loop->>Guard: response_contains_prompt_leak?(response)
                Guard-->>Loop: false (or replaces with refusal)
                Loop->>Bus: emit(:agent_response, payload)
                Loop->>Mem: append(:assistant, response, session_id)
                Loop->>Chan: deliver response
            else result has tool_calls
                Loop->>Bus: emit(:tool_call, payload)
                Loop->>Hooks: run(:pre_tool_use, {tool_name, args, session_id})
                alt hook returns {:blocked, reason}
                    Hooks-->>Loop: {:blocked, reason}
                    Note over Loop: tool blocked — append error message
                else hook returns :ok
                    Hooks-->>Loop: :ok
                    Loop->>ToolEx: execute_tool_call(tool_call, state)
                    ToolEx->>Tools: execute(tool_name, enriched_args)
                    Tools-->>ToolEx: {:ok, result} | {:error, reason}
                    ToolEx->>Bus: emit(:tool_result, payload)
                    ToolEx-->>Loop: tool_result_string
                    Loop->>Hooks: run(:post_tool_use, {tool_name, result})
                end
                Note over Loop: append tool results to messages<br/>re-prompt LLM
            end

            alt iteration >= max_iterations
                Note over Loop: exceeded max iterations — return partial response
            end
        end
    end

    Bus->>Bus: emit(:signal_classified, enriched_signal)
    Note over Bus: async LLM classification arrives<br/>after response already delivered
```

---

## Key Decision Points

### Noise Filter (pre-persistence)

`Channels.NoiseFilter.check/2` runs before the message is persisted to memory.
Low-signal messages (weight < 0.15, greetings, single-word inputs) that would produce
no useful agent response are filtered here. This prevents meaningless turns from
filling the context window and consuming tokens.

### Guardrails (pre-LLM and post-LLM)

`Loop.Guardrails.prompt_injection?/1` runs on the raw input before anything else.
Three detection tiers (regex, unicode-normalized regex, structural analysis) block
prompt extraction attempts before the LLM sees the message.

A second check runs on the LLM output: `response_contains_prompt_leak?/1` detects
if the model echoed system prompt content (common with weak local models) and replaces
the response with a canned refusal.

### Genre Router (post-classification)

`Loop.GenreRouter.route_by_genre/3` short-circuits the LLM for messages where the
signal genre implies a deterministic response (`:inform` → memory suggestion,
`:express` → empathy response). This saves a full LLM call for common conversational
patterns.

### Tool Weight Threshold

If `signal.weight < 0.20`, no tools are included in the LLM call. This prevents
hallucinated tool sequences for inputs like "ok", "thanks", or "lol" where the user
has no actionable intent.

### Max Iterations

The ReAct loop runs up to `max_iterations` (default: 30, configurable). If the loop
reaches the limit without a final response (no tool_calls), the agent returns whatever
text it has accumulated.

---

## Event Types Emitted

| Phase | Event Type | Contents |
|---|---|---|
| Message received | `:user_message` | session_id, content, channel, signal |
| LLM call started | `:llm_request` | session_id, provider, model, message count |
| Streaming token | `:system_event` (streaming_token) | session_id, text chunk |
| Tool call started | `:tool_call` | session_id, tool name, args hint, phase: :start |
| Tool call finished | `:tool_result` | session_id, tool name, result, duration_ms |
| Response ready | `:agent_response` | session_id, content, tool_count, iteration_count |
| Signal enriched | `:signal_classified` | session_id, enriched signal, source: :llm |
