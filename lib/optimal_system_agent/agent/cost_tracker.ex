defmodule OptimalSystemAgent.Agent.CostTracker do
  @moduledoc """
  Per-agent budget tracking on top of Treasury.

  Listens for :llm_response events, records cost_events, atomically
  increments agent_budgets, and auto-pauses agents that exceed monthly limits.
  """
  use GenServer
  require Logger
  import Ecto.Query

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Store.Repo

  @check_interval_ms 60_000

  @pricing %{
    "claude-opus-4-6" => {1500, 7500},
    "claude-sonnet-4-6" => {300, 1500},
    "claude-haiku-4-5" => {80, 400},
    "gpt-4o" => {250, 1000},
    "gpt-4o-mini" => {15, 60}
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_summary, do: GenServer.call(__MODULE__, :get_summary)
  def get_by_agent, do: GenServer.call(__MODULE__, :get_by_agent)
  def get_by_model, do: GenServer.call(__MODULE__, :get_by_model)
  def get_events(opts \\ []), do: GenServer.call(__MODULE__, {:get_events, opts})
  def get_budgets, do: GenServer.call(__MODULE__, :get_budgets)
  def update_budget(agent_name, params), do: GenServer.call(__MODULE__, {:update_budget, agent_name, params})
  def reset_budget(agent_name), do: GenServer.call(__MODULE__, {:reset_budget, agent_name})

  @impl true
  def init(_opts) do
    try do
      Bus.register_handler(:llm_response, fn payload ->
        send(__MODULE__, {:llm_response, payload})
      end)
    catch
      :exit, reason ->
        Logger.warning("[CostTracker] Could not register handler: #{inspect(reason)}")
    end

    Process.send_after(self(), :check_resets, @check_interval_ms)
    Logger.info("[CostTracker] Started")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:llm_response, payload}, state) do
    record_cost(payload)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_resets, state) do
    check_and_apply_resets()
    Process.send_after(self(), :check_resets, @check_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_summary, _from, state) do
    today = Date.utc_today()
    month_start = Date.beginning_of_month(today)

    daily = Repo.one(
      from ce in "cost_events",
        where: fragment("date(ce.inserted_at) = ?", ^Date.to_iso8601(today)),
        select: %{spent: sum(ce.cost_cents), events: count(ce.id)}
    )

    monthly = Repo.one(
      from ce in "cost_events",
        where: fragment("date(ce.inserted_at) >= ?", ^Date.to_iso8601(month_start)),
        select: %{spent: sum(ce.cost_cents), events: count(ce.id)}
    )

    daily_limit = parse_float_env("OSA_TREASURY_DAILY_LIMIT", 250.0)
    monthly_limit = parse_float_env("OSA_TREASURY_MONTHLY_LIMIT", 2500.0)

    result = %{
      daily_spent_cents: daily[:spent] || 0,
      daily_events: daily[:events] || 0,
      monthly_spent_cents: monthly[:spent] || 0,
      monthly_events: monthly[:events] || 0,
      daily_limit_cents: round(daily_limit * 100),
      monthly_limit_cents: round(monthly_limit * 100)
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_by_agent, _from, state) do
    {:reply, Repo.all(from ab in "agent_budgets", select: ab), state}
  end

  @impl true
  def handle_call(:get_by_model, _from, state) do
    rows = Repo.all(
      from ce in "cost_events",
        group_by: ce.model,
        select: %{model: ce.model, total_cents: sum(ce.cost_cents), event_count: count(ce.id)}
    )
    {:reply, rows, state}
  end

  @impl true
  def handle_call({:get_events, opts}, _from, state) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    agent_name = Keyword.get(opts, :agent_name)
    offset = (page - 1) * per_page

    query = from ce in "cost_events",
      order_by: [desc: ce.inserted_at],
      limit: ^per_page,
      offset: ^offset,
      select: ce

    query = if agent_name,
      do: where(query, [ce], ce.agent_name == ^agent_name),
      else: query

    {:reply, Repo.all(query), state}
  end

  @impl true
  def handle_call(:get_budgets, _from, state) do
    {:reply, Repo.all(from ab in "agent_budgets", select: ab), state}
  end

  @impl true
  def handle_call({:update_budget, agent_name, params}, _from, state) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    daily = Keyword.get(params, :budget_daily_cents, 25_000)
    monthly = Keyword.get(params, :budget_monthly_cents, 250_000)

    Repo.query!(
      """
      INSERT INTO agent_budgets (agent_name, budget_daily_cents, budget_monthly_cents,
        spent_daily_cents, spent_monthly_cents, status, inserted_at, updated_at)
      VALUES (?, ?, ?, 0, 0, 'active', ?, ?)
      ON CONFLICT (agent_name) DO UPDATE SET
        budget_daily_cents = excluded.budget_daily_cents,
        budget_monthly_cents = excluded.budget_monthly_cents,
        updated_at = excluded.updated_at
      """,
      [agent_name, daily, monthly, now, now]
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:reset_budget, agent_name}, _from, state) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    today = Date.utc_today()

    result = Repo.update_all(
      from(ab in "agent_budgets", where: ab.agent_name == ^agent_name),
      set: [
        spent_daily_cents: 0,
        spent_monthly_cents: 0,
        last_reset_daily: today,
        last_reset_monthly: today,
        status: "active",
        updated_at: now
      ]
    )

    {:reply, result, state}
  end

  # -- Private --------------------------------------------------------------

  defp record_cost(payload) do
    usage = payload[:usage] || %{}
    input = max(0, usage[:input_tokens] || 0)
    output = max(0, usage[:output_tokens] || 0)
    cache_read = max(0, usage[:cache_read_input_tokens] || 0)
    cache_write = max(0, usage[:cache_creation_input_tokens] || 0)
    model = payload[:model] || "unknown"
    provider = payload[:provider] || "unknown"
    agent_name = payload[:agent_name] || "default"
    cost_cents = calc_cost(model, input + cache_read + cache_write, output)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all("cost_events", [
      %{
        agent_name: agent_name,
        session_id: payload[:session_id],
        task_id: payload[:task_id],
        provider: provider,
        model: model,
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: cache_read,
        cache_write_tokens: cache_write,
        cost_cents: cost_cents,
        inserted_at: now,
        updated_at: now
      }
    ])

    upsert_budget(agent_name, cost_cents)
    check_budget_exceeded(agent_name)
  end

  defp calc_cost(model, input, output) do
    {in_rate, out_rate} = Map.get(@pricing, model, {100, 300})
    cents = (input * in_rate + output * out_rate) / 1_000_000
    ceil(cents)
  end

  defp upsert_budget(agent_name, cost_cents) do
    today = Date.utc_today()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.query!(
      """
      INSERT INTO agent_budgets (agent_name, budget_daily_cents, budget_monthly_cents,
        spent_daily_cents, spent_monthly_cents, status, last_reset_daily,
        last_reset_monthly, inserted_at, updated_at)
      VALUES (?, 25000, 250000, ?, ?, 'active', ?, ?, ?, ?)
      ON CONFLICT (agent_name) DO UPDATE SET
        spent_daily_cents = spent_daily_cents + excluded.spent_daily_cents,
        spent_monthly_cents = spent_monthly_cents + excluded.spent_monthly_cents,
        updated_at = excluded.updated_at
      """,
      [agent_name, cost_cents, cost_cents, today, today, now, now]
    )
  end

  defp check_budget_exceeded(agent_name) do
    {count, _} = Repo.update_all(
      from(ab in "agent_budgets",
        where:
          ab.agent_name == ^agent_name and
            ab.status != "paused_budget" and
            ab.budget_monthly_cents > 0 and
            ab.spent_monthly_cents >= ab.budget_monthly_cents
      ),
      set: [status: "paused_budget"]
    )

    if count > 0 do
      row = Repo.one(from ab in "agent_budgets", where: ab.agent_name == ^agent_name,
        select: %{spent: ab.spent_monthly_cents, budget: ab.budget_monthly_cents})

      Bus.emit(:system_event, %{
        event: :budget_exceeded,
        agent_name: agent_name,
        spent: row[:spent],
        budget: row[:budget]
      })

      Logger.warning("[CostTracker] Agent #{agent_name} paused — budget exceeded")
    end
  end

  defp check_and_apply_resets do
    today = Date.utc_today()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.update_all(
      from(ab in "agent_budgets",
        where: is_nil(ab.last_reset_daily) or fragment("? < ?", ab.last_reset_daily, ^today)
      ),
      set: [spent_daily_cents: 0, last_reset_daily: today, updated_at: now]
    )

    Repo.update_all(
      from(ab in "agent_budgets",
        where:
          is_nil(ab.last_reset_monthly) or
            fragment("strftime('%Y-%m', ?) < strftime('%Y-%m', ?)", ab.last_reset_monthly, ^today)
      ),
      set: [spent_monthly_cents: 0, last_reset_monthly: today, updated_at: now]
    )
  end

  defp parse_float_env(env_var, default) do
    case System.get_env(env_var) do
      nil -> default
      val ->
        case Float.parse(val) do
          {f, _} -> f
          :error -> default
        end
    end
  end
end
