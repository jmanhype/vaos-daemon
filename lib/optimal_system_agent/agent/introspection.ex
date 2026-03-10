defmodule OptimalSystemAgent.Agent.Introspection do

  alias OptimalSystemAgent.Agent.Loop

  def all_sessions do
    Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  rescue
    _ -> []
  end

  def session_state(session_id) do
    Loop.get_state(session_id)
  end

  def snapshot do
    sids = all_sessions()
    sessions = Enum.reject(Enum.map(sids, fn sid ->
      case session_state(sid) do
        {:ok, s} -> s
        {:error, _} -> nil
      end
    end), &is_nil/1)
    n = length(sessions)
    Map.new([{:sessions, sessions}, {:total_sessions, n}, {:timestamp, DateTime.utc_now()}])
  end
end
