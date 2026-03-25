defmodule Daemon.BudgetEmitter do
  @moduledoc "Bridge from MiosaBudget events to OSA Events.Bus."
  @behaviour MiosaBudget.Emitter

  @impl true
  def emit(topic, payload) do
    Daemon.Events.Bus.emit(topic, payload)
  end
end
