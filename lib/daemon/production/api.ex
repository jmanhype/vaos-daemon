defmodule Daemon.Production.API do
  @moduledoc "HTTP routes for Film Production pipeline."
  use Plug.Router

  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :match
  plug :dispatch

  post "/" do
    brief = %{
      title: conn.body_params["title"] || "Untitled",
      character_bible: conn.body_params["character_bible"] || "",
      preset: conn.body_params["preset"] || "",
      reference_image: conn.body_params["reference_image"],
      scenes: Enum.map(conn.body_params["scenes"] || [], fn s ->
        %{title: s["title"] || "", prompt: s["prompt"] || ""}
      end)
    }

    case Daemon.Production.FilmPipeline.produce(brief) do
      :ok ->
        send_resp(conn, 202, Jason.encode!(%{status: "started", title: brief.title, reference_image: brief.reference_image}))
      {:error, reason} ->
        send_resp(conn, 409, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  get "/status" do
    status = Daemon.Production.FilmPipeline.status()
    send_resp(conn, 200, Jason.encode!(%{status: inspect(status)}))
  end

  post "/abort" do
    Daemon.Production.FilmPipeline.abort()
    send_resp(conn, 200, Jason.encode!(%{status: "aborted"}))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not_found"}))
  end
end
