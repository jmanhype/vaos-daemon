# Custom Tools

OSA supports defining custom tools at runtime via the SDK. Custom tools integrate into the same registry as builtins, appear in every agent's tool list, and execute with the same middleware pipeline.

---

## SDK Tool Definition

`OptimalSystemAgent.SDK.Tool.define/4` creates a tool from a closure and registers it immediately.

```elixir
OptimalSystemAgent.SDK.Tool.define(
  "weather",                    # tool name (must be unique)
  "Get current weather for a city",  # description shown to LLM
  %{                            # JSON Schema for parameters
    "type" => "object",
    "properties" => %{
      "city" => %{
        "type" => "string",
        "description" => "City name"
      }
    },
    "required" => ["city"]
  },
  fn %{"city" => city} ->       # handler function
    {:ok, "Weather in #{city}: 72°F, sunny"}
  end
)
```

Returns `:ok` on success or `{:error, reason}` on failure.

---

## How It Works

1. **Handler storage** — the closure is stored in `:persistent_term` under `{SDK.Tool, :handler, name}` for lock-free execution. This means the handler is accessible without going through any GenServer.

2. **Module creation** — `Module.create/3` compiles a new BEAM module at runtime implementing `MiosaTools.Behaviour`:
   ```elixir
   # Generated module (pseudocode)
   defmodule OptimalSystemAgent.SDK.Tools.Weather do
     @behaviour MiosaTools.Behaviour
     def name, do: "weather"
     def description, do: "Get current weather for a city"
     def parameters, do: %{...}
     def execute(args) do
       handler = :persistent_term.get({SDK.Tool, :handler, "weather"})
       handler.(args)
     end
   end
   ```

3. **Registration** — the module is passed to `Tools.Registry.register/1`, which triggers Goldrush dispatch recompilation and writes the updated tool list to `:persistent_term`.

After registration, the tool is immediately available to all agents — no restart required.

---

## Tool Schema

The `parameters` map must be a valid JSON Schema object. OSA uses this schema for:
- Input validation before calling `execute/1`
- Generating the `parameters` field in LLM tool definitions
- Documentation and introspection

### Supported JSON Schema features

| Feature | Example |
|---------|---------|
| `type: "string"` | String parameters |
| `type: "integer"` | Integer parameters |
| `type: "number"` | Float parameters |
| `type: "boolean"` | Boolean flags |
| `type: "array"` | List of items |
| `type: "object"` | Nested objects |
| `required: [...]` | Required field list |
| `enum: [...]` | Restricted value set |
| `description` | Field description for LLM |

### Example schemas

**Simple string parameter:**
```elixir
%{
  "type" => "object",
  "properties" => %{
    "query" => %{"type" => "string", "description" => "Search query"}
  },
  "required" => ["query"]
}
```

**Enum parameter:**
```elixir
%{
  "type" => "object",
  "properties" => %{
    "format" => %{
      "type" => "string",
      "enum" => ["json", "csv", "text"],
      "description" => "Output format"
    }
  },
  "required" => ["format"]
}
```

**Array parameter:**
```elixir
%{
  "type" => "object",
  "properties" => %{
    "files" => %{
      "type" => "array",
      "items" => %{"type" => "string"},
      "description" => "List of file paths"
    }
  },
  "required" => ["files"]
}
```

---

## Handler Contract

The handler is a 1-arity function receiving the `args` map and returning either:

```elixir
{:ok, String.t()}    # success — result shown to LLM
{:error, String.t()} # failure — error shown to LLM
```

The `args` map keys are always strings (not atoms), matching the JSON Schema property names.

### Guidelines for handlers

- Return concise, informative strings — LLMs work better with structured text than raw data dumps
- Handle missing or malformed input defensively — the middleware validates against schema but type coercions can still produce unexpected values
- Keep handlers fast — agent iterations are sequential; slow tools block the loop
- Do not call `Tools.execute/2` (GenServer) from inside a handler — use `Tools.execute_direct/2` instead to avoid deadlocks

---

## Removing a Tool

```elixir
OptimalSystemAgent.SDK.Tool.undefine("weather")
```

Removes the handler from `:persistent_term`. The module remains compiled but calls to `execute/1` will raise a missing key error. To fully remove the tool from the registry, restart the Tools.Registry process or call `Tools.Registry.deregister/1` if available.

---

## Building Tool Definitions Without Registering

For one-off tools passed to specific agent calls via `:extra_tools`:

```elixir
tool_def = OptimalSystemAgent.SDK.Tool.build_tool_def(
  "summarize",
  "Summarize a block of text",
  %{
    "type" => "object",
    "properties" => %{
      "text" => %{"type" => "string"}
    },
    "required" => ["text"]
  }
)

# Pass to Loop
OptimalSystemAgent.Agent.Loop.run(message, session_id, extra_tools: [tool_def])
```

`build_tool_def/3` returns a plain map — no registration, no module creation. The tool appears in the LLM's tool list for that run only.

---

## Implementing `MiosaTools.Behaviour` Directly

For tools that need compile-time behavior (optional callbacks, availability checks, or safety levels), implement the behaviour directly:

```elixir
defmodule MyApp.Tools.DatabaseQuery do
  @behaviour MiosaTools.Behaviour

  @impl true
  def name, do: "db_query"

  @impl true
  def description, do: "Run a read-only SQL query against the application database"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "sql" => %{"type" => "string", "description" => "SELECT query to execute"},
        "limit" => %{"type" => "integer", "description" => "Max rows (default: 50)"}
      },
      "required" => ["sql"]
    }
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def available? do
    # Check database connection is alive
    MyApp.Repo.connected?()
  end

  @impl true
  def execute(%{"sql" => sql} = args) do
    # Enforce read-only
    if String.match?(String.upcase(String.trim(sql)), ~r/^SELECT\b/) do
      limit = Map.get(args, "limit", 50)
      rows = MyApp.Repo.query!(sql <> " LIMIT #{limit}", []).rows
      {:ok, format_rows(rows)}
    else
      {:error, "Only SELECT queries are allowed"}
    end
  end

  defp format_rows(rows) do
    rows
    |> Enum.map(&inspect/1)
    |> Enum.join("\n")
  end
end

# Register on application start
OptimalSystemAgent.Tools.Registry.register(MyApp.Tools.DatabaseQuery)
```

---

## Testing Custom Tools

Custom tools can be tested in isolation without running the full agent loop:

```elixir
defmodule MyApp.Tools.WeatherTest do
  use ExUnit.Case

  test "returns weather for a valid city" do
    assert {:ok, result} = MyApp.Tools.Weather.execute(%{"city" => "San Francisco"})
    assert String.contains?(result, "San Francisco")
  end

  test "handles missing city parameter" do
    assert {:error, _reason} = MyApp.Tools.Weather.execute(%{})
  end
end
```

---

## See Also

- [Tools Overview](./overview.md)
- [File Tools](./file-tools.md)
- [Integration Tools](./integration-tools.md)
- [SDK Supervisor](../../lib/optimal_system_agent/sdk/supervisor.ex)
