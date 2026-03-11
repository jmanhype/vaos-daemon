defmodule OptimalSystemAgent.Channels.HTTP.API.ToolSynthesisRoutes do
  @moduledoc """
  HTTP routes for Zero-Shot Tool Synthesis.

  Forwarded from `/agent/tools/synthesize` in the main API router.

  Endpoints:
    POST   /          Synthesize a new tool module from a spec
    GET    /          List all synthesized tools
    DELETE /:name     Delete a synthesized tool by name
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Tools.Synthesizer

  @name_regex ~r/^[a-z][a-z0-9_-]*$/

  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :dispatch

  # ── POST / — synthesize a new tool ────────────────────────────────────────

  post "/" do
    body = conn.body_params
    name = body["name"]
    description = body["description"]
    params = body["params"]
    tool_body = body["body"]

    cond do
      not (is_binary(name) and name != "") ->
        json_error(conn, 400, "missing_name", "Field 'name' (kebab-case string) is required")

      not Regex.match?(@name_regex, name) ->
        json_error(
          conn,
          400,
          "invalid_name",
          "Tool name must match ^[a-z][a-z0-9_-]*$. Got: #{name}"
        )

      not is_binary(description) ->
        json_error(conn, 400, "missing_description", "Field 'description' (string) is required")

      not is_list(params) ->
        json_error(conn, 400, "invalid_params", "Field 'params' must be a list of strings")

      not (is_binary(tool_body) and tool_body != "") ->
        json_error(conn, 400, "missing_body", "Field 'body' (non-empty string) is required")

      true ->
        spec = %{
          "description" => description,
          "params" => params,
          "body" => tool_body
        }

        result =
          try do
            Synthesizer.synthesize(name, spec)
          catch
            :exit, _ -> {:error, "synthesizer process not available"}
          rescue
            e -> {:error, Exception.message(e)}
          end

        case result do
          {:ok, module_name} ->
            resp =
              Jason.encode!(%{
                status: "synthesized",
                module: module_name,
                name: name
              })

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, resp)

          {:error, reason} ->
            Logger.error("[ToolSynthesisRoutes] Synthesis failed for '#{name}': #{inspect(reason)}")
            json_error(conn, 500, "synthesis_failed", to_string(reason))
        end
    end
  end

  # ── GET / — list synthesized tools ────────────────────────────────────────

  get "/" do
    tools =
      try do
        Synthesizer.list_synthesized()
      catch
        :exit, _ -> []
      rescue
        _ -> []
      end

    body = Jason.encode!(%{tools: tools, count: length(tools)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── DELETE /:name — delete a synthesized tool ──────────────────────────────

  delete "/:name" do
    tool_name = conn.params["name"]

    result =
      try do
        Synthesizer.delete_synthesized(tool_name)
      catch
        :exit, _ -> {:error, "synthesizer process not available"}
      rescue
        e -> {:error, Exception.message(e)}
      end

    case result do
      :ok ->
        body = Jason.encode!(%{status: "deleted", name: tool_name})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_found} ->
        json_error(conn, 404, "not_found", "No synthesized tool named '#{tool_name}'")

      {:error, reason} ->
        Logger.error("[ToolSynthesisRoutes] Delete failed for '#{tool_name}': #{inspect(reason)}")
        json_error(conn, 500, "delete_failed", to_string(reason))
    end
  end

  # ── Catch-all ──────────────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Endpoint not found")
  end
end
