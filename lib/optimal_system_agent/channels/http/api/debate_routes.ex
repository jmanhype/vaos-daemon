defmodule OptimalSystemAgent.Channels.HTTP.API.DebateRoutes do
  @moduledoc """
  HTTP routes for the multi-agent debate feature.

  POST /debate
    Body: {
      "message":              string (required),
      "providers":            [string] (optional, list of provider names),
      "timeout":              integer (optional, ms per agent),
      "synthesizer_provider": string (optional)
    }

  Success (200):
    {
      "synthesis":    "...",
      "debate":       [{"provider": "anthropic", "response": "..."}, ...],
      "participants": 3
    }

  Errors:
    400 — message field missing or empty
    500 — all providers failed or internal error
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Agent.Debate

  @max_timeout_ms 120_000

  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :dispatch

  post "/" do
    with %{"message" => message} when is_binary(message) and message != "" <- conn.body_params do
      providers = conn.body_params["providers"]
      timeout = min(conn.body_params["timeout"] || 30_000, @max_timeout_ms)
      synthesizer = conn.body_params["synthesizer_provider"]
      user_id = conn.assigns[:user_id] || "anonymous"

      opts =
        []
        |> maybe_put(:providers, providers)
        |> maybe_put(:timeout, timeout)
        |> maybe_put(:synthesizer_provider, synthesizer)
        |> Keyword.put(:user_id, user_id)

      case Debate.run(message, opts) do
        {:ok, %{synthesis: synthesis, debate: debate_list, participants: n}} ->
          debate_json =
            Enum.map(debate_list, fn %{provider: p, response: r} ->
              %{"provider" => p, "response" => r}
            end)

          body =
            Jason.encode!(%{
              "synthesis" => synthesis,
              "debate" => debate_json,
              "participants" => n
            })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:error, :no_providers} ->
          json_error(conn, 400, "invalid_request", "providers list must not be empty")

        {:error, reason} ->
          Logger.error("[debate_routes] Debate failed: #{inspect(reason)}")
          json_error(conn, 500, "debate_failed", "All providers failed to respond")
      end
    else
      %{"message" => _} ->
        json_error(conn, 400, "invalid_request", "message must be a non-empty string")

      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: message")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Endpoint not found")
  end
end
