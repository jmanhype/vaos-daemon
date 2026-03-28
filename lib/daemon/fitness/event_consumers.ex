defmodule Daemon.Fitness.EventConsumers do
  @moduledoc """
  Fitness function: every event type has at least one real consumer.

  Checks that each event type in the Bus has a handler beyond the default
  Bridge.PubSub broadcast. Fire-and-forget types (channel lifecycle) are exempt.
  """

  @behaviour Daemon.Fitness

  # Fire-and-forget event types that legitimately have no persistent handler
  @expected_no_handler [:channel_connected, :channel_disconnected, :channel_error]

  @impl true
  def name, do: "event_consumers"

  @impl true
  def description, do: "Every event type has at least one real consumer (beyond Bridge.PubSub broadcast)"

  @impl true
  def evaluate(_workspace) do
    event_types = Daemon.Events.Bus.event_types()
    handler_counts = collect_handler_counts()

    # Types with only the Bridge.PubSub broadcast handler (count <= 1)
    unsubscribed =
      Enum.filter(event_types, fn type ->
        Map.get(handler_counts, type, 0) <= 1
      end)

    true_violations = unsubscribed -- @expected_no_handler

    if true_violations == [] do
      {:kept, 1.0, "All event types have consumers"}
    else
      score = 1.0 - length(true_violations) / length(event_types)

      detail =
        Enum.map_join(true_violations, "\n", fn type ->
          "Event type :#{type} has no real consumer (only Bridge.PubSub broadcast)"
        end)

      {:not_kept, score, detail}
    end
  end

  defp collect_handler_counts do
    :ets.tab2list(:daemon_event_handlers)
    |> Enum.group_by(fn
      {event_type, _ref, _fn} -> event_type
      {event_type, _fn} -> event_type
    end)
    |> Map.new(fn {k, v} -> {k, length(v)} end)
  rescue
    _ -> %{}
  end
end
