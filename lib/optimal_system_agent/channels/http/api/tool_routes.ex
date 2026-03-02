defmodule OptimalSystemAgent.Channels.HTTP.API.ToolRoutes do
  @moduledoc """
  Tools, skills, and commands routes.

  This module is forwarded to from three prefixes in the parent router:
    forward "/tools"    → GET /, POST /:name/execute
    forward "/skills"   → GET /, POST /create
    forward "/commands" → GET /, POST /execute

  Effective endpoints:
    GET  /tools
    POST /tools/:name/execute
    GET  /skills
    POST /skills/create
    GET  /commands
    POST /commands/execute
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Tools.Registry, as: Tools
  alias OptimalSystemAgent.Commands
  alias OptimalSystemAgent.Agent.Orchestrator, as: TaskOrchestrator

  plug :match
  plug :dispatch

  # ── GET / ─────────────────────────────────────────────────────────
  # Handles GET /tools, GET /skills, GET /commands after prefix strip.
  # Disambiguate by path_info on the conn.

  get "/" do
    case conn.path_info do
      _ ->
        # Determine which resource by looking at the script_name
        # (the stripped prefix is in conn.script_name after forward)
        case List.last(conn.script_name) do
          "skills" -> handle_list_skills(conn)
          "commands" -> handle_list_commands(conn)
          _ -> handle_list_tools(conn)
        end
    end
  end

  # ── POST /create (skills) ─────────────────────────────────────────

  post "/create" do
    with %{"name" => name, "description" => desc, "instructions" => instructions}
         when is_binary(name) and is_binary(desc) and is_binary(instructions) <- conn.body_params do
      tools = conn.body_params["tools"] || []

      case TaskOrchestrator.create_skill(name, desc, instructions, tools) do
        {:ok, _} ->
          body =
            Jason.encode!(%{
              status: "created",
              name: name,
              message: "Skill '#{name}' created and registered at ~/.osa/skills/#{name}/SKILL.md"
            })

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, body)

        {:error, reason} ->
          json_error(conn, 422, "skill_creation_error", inspect(reason))
      end
    else
      _ ->
        json_error(
          conn,
          400,
          "invalid_request",
          "Missing required fields: name, description, instructions"
        )
    end
  end

  # ── POST /execute (commands) ───────────────────────────────────────

  post "/execute" do
    with %{"command" => command} when is_binary(command) <- conn.body_params do
      arg = conn.body_params["arg"] || ""
      session_id = conn.body_params["session_id"] || "http-#{:erlang.unique_integer([:positive])}"

      input = if arg == "", do: command, else: "#{command} #{arg}"

      {kind, output, action} =
        case Commands.execute(input, session_id) do
          {:command, text} -> {"text", text, ""}
          {:prompt, text} -> {"prompt", text, ""}
          {:action, act, text} -> {"action", text, inspect(act)}
          :unknown -> {"error", "Unknown command: #{command}", ""}
        end

      body = Jason.encode!(%{kind: kind, output: output, action: action})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: command")
    end
  end

  # ── POST /:name/execute (tools) ────────────────────────────────────

  post "/:name/execute" do
    tool_name = conn.params["name"]
    arguments = conn.body_params["arguments"] || %{}

    case Tools.execute(tool_name, arguments) do
      {:ok, result} ->
        body =
          Jason.encode!(%{
            tool: tool_name,
            status: "completed",
            result: result
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} ->
        json_error(conn, 422, "tool_error", to_string(reason))
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Tool endpoint not found")
  end

  # ── Private handlers ────────────────────────────────────────────────

  defp handle_list_tools(conn) do
    tools = Tools.list_tools()

    body =
      Jason.encode!(%{
        tools: tools,
        count: length(tools)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp handle_list_skills(conn) do
    skills = Tools.load_skill_definitions()

    summaries =
      Enum.map(skills, &Map.take(&1, [:name, :description, :category, :triggers, :priority]))

    body = Jason.encode!(%{skills: summaries, count: length(summaries)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp handle_list_commands(conn) do
    commands =
      Commands.list_commands()
      |> Enum.map(fn {name, description, category} ->
        %{name: name, description: description, category: category}
      end)

    body = Jason.encode!(%{commands: commands, count: length(commands)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end
end
