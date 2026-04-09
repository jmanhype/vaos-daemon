defmodule Daemon.Channels.HTTP.HealthTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Daemon.Channels.HTTP

  @opts HTTP.init([])

  setup do
    keys = [:default_provider, :default_model, :zhipu_model, :ollama_model]

    original =
      Enum.into(keys, %{}, fn key ->
        {key, Application.get_env(:daemon, key, :__missing__)}
      end)

    on_exit(fn ->
      Enum.each(original, fn
        {key, :__missing__} -> Application.delete_env(:daemon, key)
        {key, value} -> Application.put_env(:daemon, key, value)
      end)
    end)

    :ok
  end

  test "reports provider-specific active model instead of stale default_model" do
    Application.put_env(:daemon, :default_provider, :zhipu)
    Application.put_env(:daemon, :default_model, "glm-4.7")
    Application.put_env(:daemon, :zhipu_model, "glm-5.1")

    conn = conn(:get, "/health") |> HTTP.call(@opts)
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 200
    assert body["provider"] == "zhipu"
    assert body["model"] == "glm-5.1"
  end

  test "falls back to default_model when provider-specific model is absent" do
    Application.put_env(:daemon, :default_provider, :zhipu)
    Application.put_env(:daemon, :default_model, "glm-5.1")
    Application.delete_env(:daemon, :zhipu_model)

    conn = conn(:get, "/health") |> HTTP.call(@opts)
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 200
    assert body["model"] == "glm-5.1"
  end
end
