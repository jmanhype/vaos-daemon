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
    GET  /commands           — list all commands
    GET  /commands?q=term    — fuzzy-search commands + skills, ranked by relevance
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

  # ── POST /match — dry-run skill matching for a message ──────────────
  # Returns which skills would be triggered for a given message, without
  # actually running any agent. Useful for debugging and UI previews.

  post "/match" do
    message = conn.body_params["message"]

    cond do
      not (is_binary(message) && message != "") ->
        json_error(conn, 400, "missing_message", "'message' (non-empty string) is required")

      true ->
        matched = Tools.match_skill_triggers(message)

        skills =
          Enum.map(matched, fn {name, skill} ->
            %{
              name: name,
              description: Map.get(skill, :description, ""),
              triggers: Map.get(skill, :triggers, []),
              has_instructions: Map.get(skill, :instructions, "") != ""
            }
          end)

        body =
          Jason.encode!(%{
            message_preview: String.slice(message, 0, 120),
            matched_count: length(skills),
            skills: skills
          })

        conn |> put_resp_content_type("application/json") |> send_resp(200, body)
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
    conn = Plug.Conn.fetch_query_params(conn)
    q = conn.query_params["q"]

    if is_binary(q) and q != "" do
      handle_command_palette_search(conn, q)
    else
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

  # Fuzzy command palette: merges commands and skills, ranked by relevance score.
  #
  # Scoring uses a simple substring match strategy:
  #   - name exact match:      1.0
  #   - name starts with q:   0.8
  #   - name contains q:      0.6
  #   - description contains q: 0.3
  #
  # Commands and skills with score > 0.0 are included. Results are sorted
  # descending by score. Type field distinguishes "command" from "skill".
  defp handle_command_palette_search(conn, q) do
    q_lower = String.downcase(q)

    command_results =
      Commands.list_commands()
      |> Enum.map(fn {name, description, category} ->
        score = fuzzy_score(name, description, q_lower)
        %{type: "command", name: name, description: description, category: category, score: score}
      end)
      |> Enum.filter(fn item -> item.score > 0.0 end)

    skill_results =
      Tools.search(q)
      |> Enum.map(fn {name, description, score} ->
        %{type: "skill", name: name, description: description, category: "skill", score: score}
      end)

    all =
      (command_results ++ skill_results)
      |> Enum.sort_by(fn item -> item.score end, :desc)

    body = Jason.encode!(%{results: all, count: length(all), query: q})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # Score a name + description pair against a lowercase query token.
  defp fuzzy_score(name, description, q_lower) do
    name_lower = String.downcase(name)
    desc_lower = String.downcase(description)

    cond do
      name_lower == q_lower -> 1.0
      String.starts_with?(name_lower, q_lower) -> 0.8
      String.contains?(name_lower, q_lower) -> 0.6
      String.contains?(desc_lower, q_lower) -> 0.3
      true -> 0.0
    end
  end
end
