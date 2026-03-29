defmodule Daemon.Channels.HTTP.API.InvestigateRoutesTest do
  use ExUnit.Case, async: true
  use Plug.Test

  @opts Daemon.Channels.HTTP.API.InvestigateRoutes.init([])

  describe "POST /" do
    test "requires topic parameter" do
      conn =
        conn(:post, "/", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> Daemon.Channels.HTTP.API.InvestigateRoutes.call(@opts)

      assert conn.status == 400
      assert conn.resp_body =~ "Missing required field: topic"
    end

    test "returns investigation_id for valid request" do
      conn =
        conn(:post, "/", Jason.encode!(%{"topic" => "test claim"}))
        |> put_req_header("content-type", "application/json")
        |> Daemon.Channels.HTTP.API.InvestigateRoutes.call(@opts)

      assert conn.status == 202

      response = Jason.decode!(conn.resp_body)
      assert response["status"] == "started"
      assert response["topic"] == "test claim"
      assert response["investigation_id"] =~ ~r/^inv_[a-f0-9]{16}$/
    end
  end
end
