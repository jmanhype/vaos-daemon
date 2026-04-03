defmodule Daemon.Production.API do
  @moduledoc "HTTP routes for Film Production pipeline (v2 + v3 auto-detect)."
  use Plug.Router

  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :match
  plug :dispatch

  post "/" do
    params = conn.body_params

    # Auto-detect v3: if "ingredients" map present, use multi-ingredient pipeline
    if is_map(params["ingredients"]) && map_size(params["ingredients"]) > 0 do
      produce_v3(conn, params)
    else
      produce_v2(conn, params)
    end
  end

  get "/status" do
    v2 = Daemon.Production.FilmPipeline.status()
    v3 = Daemon.Production.FilmPipelineV3.status()

    # Return whichever is active, preferring v3
    status =
      cond do
        v3.state != :idle -> Map.put(v3, :pipeline, "v3")
        v2.state != :idle -> Map.put(v2, :pipeline, "v2")
        true -> Map.put(v3, :pipeline, "idle")
      end

    send_resp(conn, 200, Jason.encode!(status))
  end

  post "/abort" do
    Daemon.Production.FilmPipeline.abort()
    Daemon.Production.FilmPipelineV3.abort()
    send_resp(conn, 200, Jason.encode!(%{status: "aborted"}))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not_found"}))
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp produce_v2(conn, params) do
    brief = %{
      title: params["title"] || "Untitled",
      character_bible: params["character_bible"] || "",
      preset: params["preset"] || "",
      reference_image: params["reference_image"],
      scenes:
        Enum.map(params["scenes"] || [], fn s ->
          %{title: s["title"] || "", prompt: s["prompt"] || ""}
        end)
    }

    case Daemon.Production.FilmPipeline.produce(brief) do
      :ok ->
        send_resp(conn, 202, Jason.encode!(%{
          status: "started",
          pipeline: "v2",
          title: brief.title
        }))

      {:error, reason} ->
        send_resp(conn, 409, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  defp produce_v3(conn, params) do
    brief = %{
      title: params["title"] || "Untitled",
      character_bible: params["character_bible"] || "",
      preset: params["preset"] || "",
      reference_image: params["reference_image"],
      ingredients: params["ingredients"] || %{},
      scenes:
        Enum.map(params["scenes"] || [], fn s ->
          %{
            title: s["title"] || "",
            prompt: s["prompt"] || "",
            ingredients: s["ingredients"] || []
          }
        end)
    }

    case Daemon.Production.FilmPipelineV3.produce(brief) do
      :ok ->
        send_resp(conn, 202, Jason.encode!(%{
          status: "started",
          pipeline: "v3",
          title: brief.title,
          ingredients: Map.keys(brief.ingredients),
          scenes: length(brief.scenes)
        }))

      {:error, reason} ->
        send_resp(conn, 409, Jason.encode!(%{error: inspect(reason)}))
    end
  end
end
