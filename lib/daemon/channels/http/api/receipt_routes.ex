defmodule Daemon.Channels.HTTP.API.ReceiptRoutes do
  @moduledoc """
  Query and replay-verify signed audit receipts.

  Endpoints:
    GET /          — list stored receipts (paginated)
    GET /verify    — replay-verify all stored receipts
    GET /:id       — fetch a single receipt by audit_id
  """
  use Plug.Router
  import Daemon.Channels.HTTP.API.Shared
  require Logger

  @signed_dir Path.join(System.user_home!(), ".daemon/receipts/signed")

  plug :match
  plug :dispatch

  # GET /verify — replay-verify all stored receipts
  get "/verify" do
    pubkey = Daemon.Receipt.Emitter.get_pubkey()

    if pubkey do
      result = Daemon.Receipt.Replayer.replay_all(pubkey)
      json(conn, 200, result)
    else
      json(conn, 503, %{error: "kernel_pubkey_unavailable", details: "Cannot verify without kernel public key"})
    end
  end

  # GET / — list receipts with pagination
  get "/" do
    {page, per_page} = pagination_params(conn)

    case File.ls(@signed_dir) do
      {:ok, files} ->
        json_files =
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.sort()

        total = length(json_files)
        start = (page - 1) * per_page

        page_files =
          json_files
          |> Enum.drop(start)
          |> Enum.take(per_page)

        receipts =
          Enum.map(page_files, fn filename ->
            path = Path.join(@signed_dir, filename)

            case File.read(path) do
              {:ok, raw} ->
                case Jason.decode(raw) do
                  {:ok, data} -> data
                  _ -> %{"_file" => filename, "_error" => "parse_failed"}
                end

              _ ->
                %{"_file" => filename, "_error" => "read_failed"}
            end
          end)

        pages = if per_page > 0, do: div(total + per_page - 1, per_page), else: 0

        json(conn, 200, %{
          receipts: receipts,
          total: total,
          page: page,
          per_page: per_page,
          pages: pages
        })

      {:error, _} ->
        json(conn, 200, %{receipts: [], total: 0, page: 1, per_page: per_page, pages: 0})
    end
  end

  # GET /:id — fetch single receipt by audit_id
  get "/:id" do
    safe_id = String.replace(id, ~r/[^a-zA-Z0-9_-]/, "_")
    path = Path.join(@signed_dir, "#{safe_id}.json")

    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, data} -> json(conn, 200, data)
          _ -> json_error(conn, 500, "parse_error", "Could not parse receipt file")
        end

      {:error, :enoent} ->
        json_error(conn, 404, "not_found", "Receipt not found")

      {:error, _} ->
        json_error(conn, 500, "read_error", "Could not read receipt file")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Endpoint not found")
  end
end
