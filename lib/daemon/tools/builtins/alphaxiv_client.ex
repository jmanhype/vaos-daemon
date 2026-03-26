defmodule Daemon.Tools.Builtins.AlphaXivClient do
  @moduledoc """
  AlphaXiv MCP client for research paper search.
  Uses anubis-mcp to connect to alphaXiv's MCP server via Streamable HTTP.
  Falls back gracefully if MCP is unavailable.
  """
  require Logger

  @alphaxiv_base_url "https://api.alphaxiv.org"
  @alphaxiv_mcp_path "/mcp/v1"
  @client_name :alphaxiv_mcp
  @token_path Path.join(System.user_home!(), ".openclaw/alphaxiv_token.txt")
  @oauth_path Path.join(System.user_home!(), ".openclaw/alphaxiv_oauth.json")

  def start_link(_opts \\ []) do
    try do
      case load_auth_headers() do
        {:expired, _exp_date} ->
          # Try auto-refresh before giving up
          case refresh_access_token() do
            {:ok, new_token} ->
              Logger.info("[alphaxiv] Auto-refreshed expired access token")
              start_mcp_client(%{"authorization" => "Bearer " <> new_token})

            {:error, reason} ->
              Logger.warning("[alphaxiv] Token expired and refresh failed: #{inspect(reason)}. Re-auth needed.")
              {:error, :token_expired}
          end

        headers ->
          start_mcp_client(headers)
      end
    rescue
      e ->
        Logger.warning("[alphaxiv] Failed to start MCP client: #{Exception.message(e)}")
        {:error, :mcp_unavailable}
    catch
      kind, reason ->
        Logger.warning("[alphaxiv] Failed to start MCP client: #{inspect(kind)} #{inspect(reason)}")
        {:error, :mcp_unavailable}
    end
  end

  @doc "Search papers by semantic embedding similarity"
  def embedding_search(query) do
    case call_tool("embedding_similarity_search", %{"query" => query}) do
      {:ok, response} -> {:ok, extract_papers(response)}
      error ->
        Logger.debug("[alphaxiv] embedding_search error: #{inspect(error)}")
        error
    end
  end

  @doc "Search papers by keywords"
  def keyword_search(query) do
    case call_tool("full_text_papers_search", %{"query" => query}) do
      {:ok, response} -> {:ok, extract_papers(response)}
      error ->
        Logger.debug("[alphaxiv] keyword_search error: #{inspect(error)}")
        error
    end
  end

  @doc "Get full paper content"
  def get_paper(arxiv_url) do
    call_tool("get_paper_content", %{"url" => arxiv_url})
  end

  @doc "Ask a question about a paper"
  def ask_paper(arxiv_url, question) do
    call_tool("answer_pdf_queries", %{"url" => arxiv_url, "query" => question})
  end

  defp call_tool(tool_name, params) do
    case GenServer.whereis(@client_name) do
      nil ->
        Logger.debug("[alphaxiv] MCP client not connected")
        {:error, :not_connected}

      _pid ->
        try do
          case Anubis.Client.call_tool(@client_name, tool_name, params, timeout: 30_000) do
            {:ok, response} ->
              Logger.debug("[alphaxiv] Got response: #{inspect(response) |> String.slice(0, 300)}")
              {:ok, response}
            {:error, _} = err -> err
          end
        rescue
          e ->
            Logger.warning("[alphaxiv] Tool call failed: #{Exception.message(e)}")
            {:error, :call_failed}
        catch
          kind, reason ->
            Logger.warning("[alphaxiv] Tool call failed: #{inspect(kind)} #{inspect(reason)}")
            {:error, :call_failed}
        end
    end
  end

  defp extract_content(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} ->
        case Jason.decode(text) do
          {:ok, decoded} when is_list(decoded) -> decoded
          {:ok, decoded} when is_map(decoded) -> [decoded]
          _ -> []
        end
      _ -> []
    end)
  end
  defp extract_content(result) when is_list(result), do: result
  defp extract_content(result) when is_map(result), do: [result]
  defp extract_content(_), do: []

  defp extract_papers(response) do
    # MCP Response has content: [%{"type" => "text", "text" => "..."}]
    # The text contains the paper results, possibly as JSON or formatted text
    text = extract_text(response)

    # Try to parse as JSON first
    case Jason.decode(text) do
      {:ok, papers} when is_list(papers) ->
        Enum.map(papers, &normalize_paper/1)
      {:ok, %{"papers" => papers}} when is_list(papers) ->
        Enum.map(papers, &normalize_paper/1)
      {:ok, %{"results" => papers}} when is_list(papers) ->
        Enum.map(papers, &normalize_paper/1)
      _ ->
        # Parse structured text response
        parse_text_papers(text)
    end
  end

  defp extract_text(response) when is_binary(response), do: response
  defp extract_text(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(fn item -> is_map(item) and Map.get(item, "type") == "text" end)
    |> Enum.map(fn item -> Map.get(item, "text", "") end)
    |> Enum.join("\n")
  end
  defp extract_text(%{result: result}) when is_map(result) do
    case Map.get(result, "content") do
      content when is_list(content) -> extract_text(%{content: content})
      _ -> inspect(result)
    end
  end
  defp extract_text(other) do
    Logger.debug("[alphaxiv] Unexpected response format: #{inspect(other) |> String.slice(0, 200)}")
    ""
  end

  defp normalize_paper(paper) when is_map(paper) do
    %{
      "title" => Map.get(paper, "title", "Unknown"),
      "abstract" => (Map.get(paper, "abstract", "") || "") |> to_string() |> String.slice(0, 200),
      "year" => (Map.get(paper, "publicationDate", Map.get(paper, "year", "unknown")) || "unknown") |> to_string() |> String.slice(0, 4),
      "citationCount" => Map.get(paper, "likes", Map.get(paper, "citationCount", 0)) || 0,
      "arxivId" => Map.get(paper, "arxivId", Map.get(paper, "id", "")) || ""
    }
  end
  defp normalize_paper(_), do: %{"title" => "Unknown", "abstract" => "", "year" => "unknown", "citationCount" => 0, "arxivId" => ""}

  defp parse_text_papers(text) do
    # Extract papers from alphaXiv formatted text response
    # Pattern: [ID=XXXX] **Title**. Published on DATE by ORG: Abstract...
    Regex.scan(~r/\[ID=([^\]]+)\]\s*\*\*([^*]+)\*\*\.\s*Published on (\d{4})[^:]*:(.+?)(?=\[ID=|\z)/s, text)
    |> Enum.map(fn [_, id, title, year, abstract] ->
      %{
        "title" => String.trim(title),
        "abstract" => String.trim(abstract) |> String.slice(0, 200),
        "year" => year,
        "citationCount" => 0,
        "arxivId" => String.trim(id)
      }
    end)
  end

  defp start_mcp_client(headers) do
    Logger.info("[alphaxiv] Starting MCP client with #{if map_size(headers) > 0, do: "auth token", else: "no auth"}")
    Anubis.Client.start_link(
      name: @client_name,
      transport: {:streamable_http, base_url: @alphaxiv_base_url, mcp_path: @alphaxiv_mcp_path, headers: headers},
      client_info: %{"name" => "VAOS", "version" => "1.0.0"},
      capabilities: %{},
      protocol_version: "2025-06-18"
    )
  end

  defp refresh_access_token do
    case File.read(@oauth_path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"refresh_token" => refresh, "client_id" => client_id, "token_endpoint" => endpoint}} ->
            body = URI.encode_query(%{
              "grant_type" => "refresh_token",
              "refresh_token" => refresh,
              "client_id" => client_id
            })
            case Req.post(endpoint, body: body, headers: [{"content-type", "application/x-www-form-urlencoded"}], receive_timeout: 10_000) do
              {:ok, %{status: 200, body: %{"access_token" => new_token} = resp}} ->
                # Save new access token
                File.write!(@token_path, new_token)
                # Update refresh token if rotated
                if new_refresh = resp["refresh_token"] do
                  oauth = Jason.decode!(json) |> Map.put("refresh_token", new_refresh)
                  if exp = resp["expires_in"] do
                    oauth = Map.put(oauth, "expires_at", System.os_time(:second) + exp)
                    File.write!(@oauth_path, Jason.encode!(oauth))
                  else
                    File.write!(@oauth_path, Jason.encode!(oauth))
                  end
                end
                {:ok, new_token}
              {:ok, %{status: status, body: body}} ->
                {:error, {:refresh_failed, status, body}}
              {:error, reason} ->
                {:error, reason}
            end
          _ -> {:error, :invalid_oauth_config}
        end
      _ -> {:error, :no_oauth_config}
    end
  end

  defp load_auth_headers do
    case File.read(@token_path) do
      {:ok, token} ->
        t = String.trim(token)
        cond do
          t == "" -> %{}
          jwt_expired?(t) -> {:expired, jwt_exp_date(t)}
          true -> %{"authorization" => "Bearer " <> t}
        end
      _ -> %{}
    end
  end

  # Decode JWT payload (base64url, no verification) and check exp claim
  defp jwt_expired?(token) do
    case decode_jwt_payload(token) do
      %{"exp" => exp} when is_integer(exp) ->
        System.os_time(:second) > exp
      _ -> false
    end
  end

  defp jwt_exp_date(token) do
    case decode_jwt_payload(token) do
      %{"exp" => exp} when is_integer(exp) ->
        exp |> DateTime.from_unix!() |> DateTime.to_iso8601()
      _ -> "unknown"
    end
  end

  defp decode_jwt_payload(token) do
    case String.split(token, ".") do
      [_, payload_b64 | _] ->
        # Add base64url padding
        padded = case rem(byte_size(payload_b64), 4) do
          2 -> payload_b64 <> "=="
          3 -> payload_b64 <> "="
          _ -> payload_b64
        end
        padded = String.replace(padded, "-", "+") |> String.replace("_", "/")
        case Base.decode64(padded) do
          {:ok, json} -> Jason.decode!(json)
          _ -> %{}
        end
      _ -> %{}
    end
  rescue
    _ -> %{}
  end
end
