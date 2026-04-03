defmodule Daemon.Production.API do
  @moduledoc "HTTP routes for Film Production pipeline."
  use Plug.Router

  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :match
  plug :dispatch

  post "/" do
    params = conn.body_params

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
            mode: s["mode"] || "new",
            ingredients: s["ingredients"] || []
          }
        end)
    }

    case Daemon.Production.FilmPipeline.produce(brief) do
      :ok ->
        send_resp(conn, 202, Jason.encode!(%{
          status: "started",
          title: brief.title,
          ingredients: Map.keys(brief.ingredients),
          scenes: length(brief.scenes)
        }))

      {:error, reason} ->
        send_resp(conn, 409, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  get "/status" do
    status = Daemon.Production.FilmPipeline.status()
    send_resp(conn, 200, Jason.encode!(status))
  end

  post "/abort" do
    Daemon.Production.FilmPipeline.abort()
    send_resp(conn, 200, Jason.encode!(%{status: "aborted"}))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not_found"}))
  end
end
