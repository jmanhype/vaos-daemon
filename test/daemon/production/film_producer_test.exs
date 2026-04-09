defmodule Daemon.Production.FilmProducerTest do
  use ExUnit.Case, async: false

  alias Daemon.Production.FilmProducer

  setup do
    unless Process.whereis(Daemon.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Daemon.PubSub})
    end

    pid = Process.whereis(FilmProducer) || start_supervised!(FilmProducer)
    FilmProducer.abort()

    %{producer: pid}
  end

  test "ignores unrelated production pubsub events without crashing", %{producer: pid} do
    ref = Process.monitor(pid)

    Phoenix.PubSub.broadcast(
      Daemon.PubSub,
      "osa:production",
      {:comfyui_scene_runner, :scene_submitted, %{run_id: "run-123"}}
    )

    Process.sleep(50)

    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
    assert Process.whereis(FilmProducer) == pid

    status = FilmProducer.status()
    assert Enum.all?(status, fn {_platform, info} -> info.status == :idle end)
  end
end
