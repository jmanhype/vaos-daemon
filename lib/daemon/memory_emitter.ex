defmodule Daemon.MemoryEmitter do
  @moduledoc "Bridge from MiosaMemory events to OSA Events.Bus."
  @behaviour MiosaMemory.Emitter

  @impl true
  def emit(topic, payload) do
    Daemon.Events.Bus.emit(topic, payload)
  end
end
