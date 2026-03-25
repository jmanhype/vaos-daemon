defmodule Daemon.Channels.HTTP.API.SkillsMarketplaceRoutesTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Daemon.Channels.HTTP.API.SkillsMarketplaceRoutes

  @opts SkillsMarketplaceRoutes.init([])

  describe "GET /" do
    test "returns list of skills" do
      conn =
        conn(:get, "/")
        |> SkillsMarketplaceRoutes.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["skills"])
      assert is_integer(body["count"])
    end

    test "each skill has required fields" do
      conn =
        conn(:get, "/")
        |> SkillsMarketplaceRoutes.call(@opts)

      body = Jason.decode!(conn.resp_body)

      for skill <- body["skills"] do
        assert Map.has_key?(skill, "id")
        assert Map.has_key?(skill, "name")
        assert Map.has_key?(skill, "description")
        assert Map.has_key?(skill, "category")
        assert Map.has_key?(skill, "source")
        assert is_boolean(skill["enabled"])
        assert is_list(skill["triggers"])
      end
    end
  end

  describe "GET /categories" do
    test "returns categories with counts" do
      conn =
        conn(:get, "/categories")
        |> SkillsMarketplaceRoutes.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["categories"])

      for cat <- body["categories"] do
        assert is_binary(cat["name"])
        assert is_integer(cat["count"])
        assert cat["count"] > 0
      end
    end
  end

  describe "GET /:id" do
    test "returns 404 for unknown skill" do
      conn =
        conn(:get, "/nonexistent-skill-xyz")
        |> SkillsMarketplaceRoutes.call(@opts)

      assert conn.status == 404
    end
  end

  describe "POST /search" do
    test "returns results for valid query" do
      conn =
        conn(:post, "/search", Jason.encode!(%{query: "file"}))
        |> put_req_header("content-type", "application/json")
        |> SkillsMarketplaceRoutes.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["results"])
      assert is_integer(body["count"])
    end

    test "returns empty results for empty query" do
      conn =
        conn(:post, "/search", Jason.encode!(%{query: ""}))
        |> put_req_header("content-type", "application/json")
        |> SkillsMarketplaceRoutes.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["results"] == []
      assert body["count"] == 0
    end
  end

  describe "PUT /:id/toggle" do
    test "returns 404 for unknown skill" do
      conn =
        conn(:put, "/nonexistent-skill-xyz/toggle")
        |> SkillsMarketplaceRoutes.call(@opts)

      assert conn.status == 404
    end
  end

  describe "POST /bulk-enable" do
    test "handles empty ids list" do
      conn =
        conn(:post, "/bulk-enable", Jason.encode!(%{ids: []}))
        |> put_req_header("content-type", "application/json")
        |> SkillsMarketplaceRoutes.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["enabled"] == []
      assert body["count"] == 0
    end
  end

  describe "POST /bulk-disable" do
    test "handles empty ids list" do
      conn =
        conn(:post, "/bulk-disable", Jason.encode!(%{ids: []}))
        |> put_req_header("content-type", "application/json")
        |> SkillsMarketplaceRoutes.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["disabled"] == []
      assert body["count"] == 0
    end
  end

  describe "catch-all" do
    test "returns 404 for unknown endpoints" do
      conn =
        conn(:get, "/unknown/path")
        |> SkillsMarketplaceRoutes.call(@opts)

      assert conn.status == 404
    end
  end
end
