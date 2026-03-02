defmodule OptimalSystemAgent.Agent.Hooks do
  @moduledoc """
  Middleware pipeline for agent lifecycle events.

  Built-in hooks (6):
    security_check   — pre_tool_use  (p10)  block dangerous shell commands
    spend_guard      — pre_tool_use  (p8)   block when budget exceeded
    mcp_cache        — pre_tool_use  (p15)  inject cached MCP schemas
    cost_tracker     — post_tool_use (p25)  record actual API spend
    mcp_cache_post   — post_tool_use (p15)  populate MCP schema cache
    telemetry        — post_tool_use (p90)  emit tool timing telemetry

  Each hook is a function that receives a payload map and returns:
    {:ok, payload}     — continue with (possibly modified) payload
    {:block, reason}   — block the action (pre_tool_use only)
    :skip              — skip this hook silently

  Hooks run in priority order (lower = first). If any hook blocks, the chain stops.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  @type hook_event ::
          :pre_tool_use
          | :post_tool_use
          | :pre_compact
          | :session_start
          | :session_end
          | :pre_response
          | :post_response
  @type hook_fn :: (map() -> {:ok, map()} | {:block, String.t()} | :skip)
  @type hook_entry :: %{
          name: String.t(),
          event: hook_event(),
          handler: hook_fn(),
          priority: integer()
        }

  defstruct hooks: %{}, metrics: %{}

  # ── Client API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a hook for an event.
  Priority: lower number = runs first. Default: 50.
  """
  @spec register(hook_event(), String.t(), hook_fn(), keyword()) :: :ok
  def register(event, name, handler, opts \\ []) do
    priority = Keyword.get(opts, :priority, 50)
    GenServer.cast(__MODULE__, {:register, event, name, handler, priority})
  end

  @doc """
  Run all hooks for an event. Returns the final payload or a block reason.
  """
  @spec run(hook_event(), map()) :: {:ok, map()} | {:blocked, String.t()}
  def run(event, payload) do
    GenServer.call(__MODULE__, {:run, event, payload}, 10_000)
  end

  @doc """
  Run hooks asynchronously (fire-and-forget). Use for post-event hooks
  whose results are not needed by the caller (e.g. post_tool_use).
  """
  @spec run_async(hook_event(), map()) :: :ok
  def run_async(event, payload) do
    GenServer.cast(__MODULE__, {:run_async, event, payload})
  end

  @doc "List registered hooks."
  @spec list_hooks() :: %{hook_event() => [%{name: String.t(), priority: integer()}]}
  def list_hooks do
    GenServer.call(__MODULE__, :list_hooks)
  end

  @doc "Get hook execution metrics."
  @spec metrics() :: map()
  def metrics do
    GenServer.call(__MODULE__, :metrics)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %__MODULE__{hooks: %{}, metrics: %{}}

    # ETS table for hot-path counters (guard against re-creation on restart)
    if :ets.whereis(:osa_hooks_counters) == :undefined do
      :ets.new(:osa_hooks_counters, [:named_table, :public, :set])
    end

    # Register built-in hooks
    state = register_builtins(state)

    Logger.info("[Hooks] Pipeline initialized with #{count_hooks(state)} hooks")
    {:ok, state}
  end

  @impl true
  def handle_cast({:register, event, name, handler, priority}, state) do
    entry = %{name: name, event: event, handler: handler, priority: priority}

    hooks_for_event = Map.get(state.hooks, event, [])
    updated = [entry | hooks_for_event] |> Enum.sort_by(& &1.priority)

    {:noreply, %{state | hooks: Map.put(state.hooks, event, updated)}}
  end

  @impl true
  def handle_cast({:run_async, event, payload}, state) do
    hooks = Map.get(state.hooks, event, [])
    started_at = System.monotonic_time(:microsecond)
    {result, state} = run_chain(hooks, payload, event, state)
    elapsed_us = System.monotonic_time(:microsecond) - started_at
    state = update_metrics(state, event, elapsed_us, result)
    {:noreply, state}
  end

  @impl true
  def handle_call({:run, event, payload}, _from, state) do
    hooks = Map.get(state.hooks, event, [])
    started_at = System.monotonic_time(:microsecond)

    {result, state} = run_chain(hooks, payload, event, state)

    elapsed_us = System.monotonic_time(:microsecond) - started_at
    state = update_metrics(state, event, elapsed_us, result)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_hooks, _from, state) do
    listing =
      state.hooks
      |> Enum.map(fn {event, hooks} ->
        {event, Enum.map(hooks, fn h -> %{name: h.name, priority: h.priority} end)}
      end)
      |> Map.new()

    {:reply, listing, state}
  end

  @impl true
  def handle_call(:metrics, _from, state) do
    {:reply, state.metrics, state}
  end

  # ── Hook Chain Execution ──────────────────────────────────────────

  defp run_chain([], payload, _event, state), do: {{:ok, payload}, state}

  defp run_chain([hook | rest], payload, event, state) do
    try do
      case hook.handler.(payload) do
        {:ok, updated_payload} ->
          run_chain(rest, updated_payload, event, state)

        {:block, reason} ->
          Logger.warning("[Hooks] #{hook.name} blocked #{event}: #{reason}")

          Bus.emit(:system_event, %{
            event: :hook_blocked,
            hook_name: hook.name,
            hook_event: event,
            reason: reason,
            session_id: Map.get(payload, :session_id, "unknown")
          })

          {{:blocked, reason}, state}

        :skip ->
          run_chain(rest, payload, event, state)

        other ->
          Logger.warning("[Hooks] #{hook.name} returned unexpected: #{inspect(other)}")
          run_chain(rest, payload, event, state)
      end
    rescue
      e ->
        Logger.error("[Hooks] #{hook.name} crashed: #{Exception.message(e)}")
        # Don't let a broken hook crash the pipeline
        run_chain(rest, payload, event, state)
    end
  end

  # ── Built-in Hooks ────────────────────────────────────────────────

  defp register_builtins(state) do
    builtins = [
      # Spend guard — blocks when budget exceeded (pre_tool_use, priority 8)
      %{
        name: "spend_guard",
        event: :pre_tool_use,
        priority: 8,
        handler: &spend_guard/1
      },

      # Security check — block dangerous commands (pre_tool_use, priority 10)
      %{
        name: "security_check",
        event: :pre_tool_use,
        priority: 10,
        handler: &security_check/1
      },

      # MCP schema cache — inject cached schema if fresh (pre_tool_use, priority 15)
      %{
        name: "mcp_cache",
        event: :pre_tool_use,
        priority: 15,
        handler: &mcp_cache_pre/1
      },

      # MCP schema cache — populate cache after tool use (post_tool_use, priority 15)
      %{
        name: "mcp_cache_post",
        event: :post_tool_use,
        priority: 15,
        handler: &mcp_cache_post/1
      },

      # Cost tracker — records actual spend after tool use (post_tool_use, priority 25)
      %{
        name: "cost_tracker",
        event: :post_tool_use,
        priority: 25,
        handler: &cost_tracker/1
      },

      # Telemetry (post_tool_use, priority 90)
      %{
        name: "telemetry",
        event: :post_tool_use,
        priority: 90,
        handler: &telemetry_hook/1
      }
    ]

    Enum.reduce(builtins, state, fn hook, acc ->
      hooks_for_event = Map.get(acc.hooks, hook.event, [])
      updated = [hook | hooks_for_event] |> Enum.sort_by(& &1.priority)
      %{acc | hooks: Map.put(acc.hooks, hook.event, updated)}
    end)
  end

  # ── Built-in Hook Implementations ────────────────────────────────

  # Block dangerous shell commands — delegates to the single source of truth.
  defp security_check(%{tool_name: "shell_execute", arguments: %{"command" => cmd}} = payload) do
    case OptimalSystemAgent.Security.ShellPolicy.validate(cmd) do
      :ok -> {:ok, payload}
      {:error, reason} -> {:block, "Blocked dangerous command: #{reason}"}
    end
  end

  defp security_check(payload), do: {:ok, payload}

  # Spend guard — check budget limits before tool execution
  defp spend_guard(payload) do
    try do
      case OptimalSystemAgent.Agent.Budget.check_budget() do
        {:ok, _remaining} ->
          {:ok, payload}

        {:over_limit, period} ->
          {:block, "Budget exceeded (#{period} limit reached). Use /budget to check status."}
      end
    catch
      :exit, _ ->
        # Budget GenServer not running — allow through
        {:ok, payload}
    end
  end

  # Cost tracker — record actual API costs after tool use
  defp cost_tracker(%{tool_name: _name, result: _result} = payload) do
    try do
      provider = Map.get(payload, :provider, "unknown")
      model = Map.get(payload, :model, "unknown")
      tokens_in = Map.get(payload, :tokens_in, 0)
      tokens_out = Map.get(payload, :tokens_out, 0)
      session_id = Map.get(payload, :session_id, "unknown")

      if tokens_in > 0 or tokens_out > 0 do
        OptimalSystemAgent.Agent.Budget.record_cost(
          provider,
          model,
          tokens_in,
          tokens_out,
          session_id
        )
      end
    catch
      :exit, _ -> :ok
    end

    {:ok, payload}
  end

  defp cost_tracker(payload), do: {:ok, payload}

  # Telemetry collection
  defp telemetry_hook(%{tool_name: name, duration_ms: ms} = payload) do
    Bus.emit(:system_event, %{
      event: :tool_telemetry,
      tool_name: name,
      duration_ms: ms,
      timestamp: DateTime.utc_now()
    })

    {:ok, payload}
  end

  defp telemetry_hook(payload), do: {:ok, payload}

  # MCP cache — pre_tool_use: inject cached schema if fresh (< 1 hour)
  defp mcp_cache_pre(%{tool_name: tool_name} = payload) when is_binary(tool_name) do
    if String.starts_with?(tool_name, "mcp_") do
      cache_key = {__MODULE__, :mcp_schema, tool_name}

      case :persistent_term.get(cache_key, nil) do
        %{schema: schema, cached_at: cached_at} ->
          age_seconds = DateTime.diff(DateTime.utc_now(), cached_at, :second)

          if age_seconds < 3600 do
            {:ok, Map.put(payload, :cached_schema, schema)}
          else
            {:ok, payload}
          end

        nil ->
          {:ok, payload}
      end
    else
      {:ok, payload}
    end
  end

  defp mcp_cache_pre(payload), do: {:ok, payload}

  # MCP cache — post_tool_use: store schema from result
  defp mcp_cache_post(%{tool_name: tool_name, result: result} = payload)
       when is_binary(tool_name) and is_binary(result) do
    if String.starts_with?(tool_name, "mcp_") do
      cache_key = {__MODULE__, :mcp_schema, tool_name}

      :persistent_term.put(cache_key, %{
        schema: result,
        cached_at: DateTime.utc_now()
      })
    end

    {:ok, payload}
  end

  defp mcp_cache_post(payload), do: {:ok, payload}

  # ── Helpers ────────────────────────────────────────────────────────

  defp count_hooks(state) do
    state.hooks |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
  end

  defp update_metrics(state, event, elapsed_us, result) do
    event_metrics = Map.get(state.metrics, event, %{calls: 0, total_us: 0, blocks: 0})

    blocks =
      case result do
        {:blocked, _} -> event_metrics.blocks + 1
        _ -> event_metrics.blocks
      end

    updated = %{
      calls: event_metrics.calls + 1,
      total_us: event_metrics.total_us + elapsed_us,
      blocks: blocks,
      avg_us: div(event_metrics.total_us + elapsed_us, event_metrics.calls + 1)
    }

    %{state | metrics: Map.put(state.metrics, event, updated)}
  end
end
