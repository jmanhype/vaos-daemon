defmodule OptimalSystemAgent.Channels.HTTP.API.AuthRoutes do
  @moduledoc """
  Auth routes — POST /login, /logout, /refresh.

  These routes are forwarded to before the JWT authenticate plug runs,
  so no bearer token is required.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Channels.HTTP.Auth

  plug :match
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 1_000_000
  plug :dispatch

  # ── POST /login ────────────────────────────────────────────────────

  post "/login" do
    user_id =
      get_in(conn.body_params, ["user_id"]) ||
        "tui_#{System.unique_integer([:positive])}"

    token = Auth.generate_token(%{"user_id" => user_id})
    refresh = Auth.generate_refresh_token(%{"user_id" => user_id})

    body =
      Jason.encode!(%{
        "token" => token,
        "refresh_token" => refresh,
        "expires_in" => 900
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /logout ───────────────────────────────────────────────────

  post "/logout" do
    # Stateless JWT — nothing to invalidate server-side
    body = Jason.encode!(%{"ok" => true})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /refresh ──────────────────────────────────────────────────

  post "/refresh" do
    refresh_token = get_in(conn.body_params, ["refresh_token"]) || ""

    case Auth.refresh(refresh_token) do
      {:ok, tokens} ->
        body =
          Jason.encode!(%{
            "token" => tokens.token,
            "refresh_token" => tokens.refresh_token,
            "expires_in" => tokens.expires_in
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} ->
        body =
          Jason.encode!(%{"error" => "refresh_failed", "details" => to_string(reason)})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, body)
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Auth endpoint not found")
  end
end
