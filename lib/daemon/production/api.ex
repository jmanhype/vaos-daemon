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

  # ── AI Studio Pipeline ────────────────────────────────────────────────

  post "/aistudio/connect" do
    case Daemon.Production.AiStudioPipeline.connect() do
      {:ok, result} ->
        send_resp(conn, 200, Jason.encode!(%{status: "connected", window: result}))

      {:error, reason} ->
        send_resp(conn, 500, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  post "/aistudio/read" do
    case Daemon.Production.AiStudioPipeline.read_page() do
      {:ok, text} ->
        send_resp(conn, 200, Jason.encode!(%{text: text}))

      {:error, reason} ->
        send_resp(conn, 400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  post "/aistudio/prompt" do
    text = conn.body_params["text"] || ""

    case Daemon.Production.AiStudioPipeline.send_prompt(text) do
      :ok ->
        send_resp(conn, 202, Jason.encode!(%{status: "sent"}))

      {:error, reason} ->
        send_resp(conn, 400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  get "/aistudio/response" do
    case Daemon.Production.AiStudioPipeline.get_response() do
      {:ok, text} ->
        send_resp(conn, 200, Jason.encode!(%{text: text}))

      {:error, reason} ->
        send_resp(conn, 400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  get "/aistudio/response/blocking" do
    timeout = String.to_integer(conn.params["timeout"] || "120000")

    case Daemon.Production.AiStudioPipeline.get_response_blocking(timeout) do
      {:ok, text} ->
        send_resp(conn, 200, Jason.encode!(%{text: text}))

      :timeout ->
        send_resp(conn, 408, Jason.encode!(%{error: "generation_timeout"}))
    end
  end

  get "/aistudio/status" do
    status = Daemon.Production.AiStudioPipeline.status()
    send_resp(conn, 200, Jason.encode!(status))
  end

  get "/aistudio/url" do
    case Daemon.Production.AiStudioPipeline.get_url() do
      {:ok, url} ->
        send_resp(conn, 200, Jason.encode!(%{url: url}))

      {:error, reason} ->
        send_resp(conn, 400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not_found"}))
  end
end
