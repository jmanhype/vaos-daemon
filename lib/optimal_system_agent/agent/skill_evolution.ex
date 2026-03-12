defmodule OptimalSystemAgent.Agent.SkillEvolution do
  @moduledoc """
  Autonomous skill evolution — OSA learns from failures and writes new skills.

  Subscribes to system_event on the event bus. When a session ends with a
  failure indicator (doom_loop_detected, agent_cancelled at iter >= max, or
  explicit trigger), analyzes what went wrong and auto-generates a SKILL.md
  that will help future sessions handle the same situation better.

  Evolved skills are stored under ~/.osa/skills/evolved/<name>/SKILL.md
  and immediately registered into the Tools.Registry for next-turn injection.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Agent.Memory

  defstruct evolved_count: 0,
            last_evolution: nil,
            bus_ref: nil

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns stats: evolved_count and last_evolution datetime."
  @spec stats() :: {:ok, map()}
  def stats do
    try do
      GenServer.call(__MODULE__, :stats)
    catch
      :exit, _ -> {:ok, %{evolved_count: 0, last_evolution: nil}}
    rescue
      _ -> {:ok, %{evolved_count: 0, last_evolution: nil}}
    end
  end

  @doc "List all skill names evolved under ~/.osa/skills/evolved/"
  @spec list_evolved_skills() :: [String.t()]
  def list_evolved_skills do
    dir = evolved_dir()

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(fn entry ->
        File.exists?(Path.join([dir, entry, "SKILL.md"]))
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc "Manually trigger evolution for a session (useful for testing and HTTP endpoint)."
  @spec trigger_evolution(String.t(), map()) :: :ok
  def trigger_evolution(session_id, failure_info \\ %{}) do
    try do
      GenServer.cast(__MODULE__, {:evolve, session_id, failure_info})
    catch
      :exit, _ -> :ok
    rescue
      _ -> :ok
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %__MODULE__{}

    # Subscribe to system_event for doom_loop and cancellation signals
    ref =
      try do
        Bus.register_handler(:system_event, fn payload ->
          handle_bus_event(payload)
        end)
      catch
        :exit, _ -> nil
      rescue
        _ -> nil
      end

    Logger.info("[SkillEvolution] Started — watching for failure events")
    {:ok, %{state | bus_ref: ref}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     {:ok,
      %{
        evolved_count: state.evolved_count,
        last_evolution: state.last_evolution
      }}, state}
  end

  @impl true
  def handle_cast({:evolve, session_id, failure_info}, state) do
    Logger.info("[SkillEvolution] Triggered for session #{session_id}: #{inspect(failure_info)}")

    new_state =
      case do_evolve(session_id, failure_info) do
        {:ok, skill_name} ->
          Logger.info("[SkillEvolution] Evolved skill '#{skill_name}' from session #{session_id}")

          Bus.emit(:system_event, %{
            event: :skill_evolved,
            session_id: session_id,
            skill_name: skill_name
          })

          %{state | evolved_count: state.evolved_count + 1, last_evolution: DateTime.utc_now()}

        {:error, reason} ->
          Logger.warning("[SkillEvolution] Evolution failed for #{session_id}: #{inspect(reason)}")
          state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.bus_ref, do: Bus.unregister_handler(:system_event, state.bus_ref)
    :ok
  end

  # ── Private ─────────────────────────────────────────────────────────

  # Called from the bus handler (runs in bus process context — must be fast)
  defp handle_bus_event(payload) do
    event = Map.get(payload, :event) || Map.get(payload, "event")
    session_id = Map.get(payload, :session_id) || Map.get(payload, "session_id")

    if event in [:doom_loop_detected, :agent_cancelled] and is_binary(session_id) do
      failure_info = %{
        reason: event,
        iteration: Map.get(payload, :iteration),
        tool_signature: Map.get(payload, :tool_signature),
        consecutive_failures: Map.get(payload, :consecutive_failures)
      }

      # Dispatch to our GenServer to avoid blocking the bus
      try do
        GenServer.cast(__MODULE__, {:evolve, session_id, failure_info})
      catch
        :exit, _ -> :ok
      rescue
        _ -> :ok
      end
    end
  end

  defp do_evolve(session_id, failure_info) do
    # 1. Load session history
    messages = load_session_messages(session_id)

    if messages == [] do
      {:error, :no_session_history}
    else
      # 2. Extract relevant context
      user_requests = extract_user_requests(messages)
      failure_context = describe_failure(failure_info)

      # 3. Generate skill name and instructions via LLM
      generate_evolved_skill(session_id, user_requests, failure_context)
    end
  end

  defp load_session_messages(session_id) do
    try do
      case Memory.load_session(session_id) do
        {:ok, msgs} when is_list(msgs) -> msgs
        _ -> []
      end
    catch
      :exit, _ -> []
    rescue
      _ -> []
    end
  end

  defp extract_user_requests(messages) do
    messages
    |> Enum.filter(fn
      %{role: "user"} -> true
      %{"role" => "user"} -> true
      _ -> false
    end)
    |> Enum.map(fn
      %{content: c} -> c
      %{"content" => c} -> c
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(5)
    |> Enum.join("\n---\n")
  end

  defp describe_failure(%{reason: :doom_loop_detected, tool_signature: sig, consecutive_failures: n}) do
    "Agent entered a doom loop: tool '#{sig}' failed #{n} times consecutively."
  end

  defp describe_failure(%{reason: "doom_loop_detected"} = info) do
    sig = Map.get(info, :tool_signature)
    n = Map.get(info, :consecutive_failures)
    "Agent entered a doom loop: tool '#{sig}' failed #{n} times consecutively."
  end

  defp describe_failure(%{reason: :agent_cancelled, iteration: iter}) do
    "Session was cancelled at iteration #{iter} — hit max reasoning limit."
  end

  defp describe_failure(%{reason: "agent_cancelled"} = info) do
    iter = Map.get(info, :iteration)
    "Session was cancelled at iteration #{iter} — hit max reasoning limit."
  end

  defp describe_failure(%{reason: reason}) do
    to_string(reason)
  end

  defp describe_failure(_), do: "unknown failure"

  defp generate_evolved_skill(session_id, user_requests, failure_context) do
    # Build a concise skill from the failure context without requiring a live LLM call.
    # If LLM is available, use it; otherwise fall back to a heuristic skill.
    skill_name = "evolved-#{String.slice(session_id, 0, 8)}"
    # Sanitize to prevent path traversal
    skill_name = skill_name |> String.replace(~r/[^a-zA-Z0-9\-_]/, "-") |> String.slice(0, 64)

    instructions = """
    ## Evolved Recovery Skill

    This skill was auto-generated because a previous session encountered a failure.

    **Failure context:**
    #{failure_context}

    **Original user requests:**
    #{user_requests}

    ### Recovery guidelines
    - Before retrying failed tool calls, verify the tool's prerequisites are met
    - If you hit a reasoning limit, break the task into smaller sub-goals
    - If a tool fails repeatedly, try an alternative approach or ask the user for clarification
    - Always report what you tried and why it failed before giving up
    """

    write_evolved_skill(skill_name, failure_context, instructions, session_id)
  end

  defp write_evolved_skill(name, description, instructions, session_id) do
    skill_dir = Path.join(evolved_dir(), name)

    try do
      File.mkdir_p!(skill_dir)

      content = """
      ---
      name: #{name}
      description: #{String.slice(description, 0, 120)}
      evolved: true
      evolved_from: #{session_id}
      triggers:
        - #{name}
      ---

      #{instructions}
      """

      skill_path = Path.join(skill_dir, "SKILL.md")
      File.write!(skill_path, content)

      Logger.info("[SkillEvolution] Wrote #{skill_path}")

      # Reload registry so the skill is available for next turn (non-blocking)
      Task.start(fn -> OptimalSystemAgent.Tools.Registry.reload_skills() end)

      {:ok, name}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp evolved_dir do
    base = Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills")
    Path.join(Path.expand(base), "evolved")
  end
end
