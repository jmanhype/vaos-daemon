defmodule OptimalSystemAgent.MemoryEmitter do
  @moduledoc "Bridge from MiosaMemory events to OSA Events.Bus."
  @behaviour MiosaMemory.Emitter

  @impl true
  def emit(topic, payload) do
    OptimalSystemAgent.Events.Bus.emit(topic, payload)
  end
end
