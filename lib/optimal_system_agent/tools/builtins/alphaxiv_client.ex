defmodule OptimalSystemAgent.Tools.Builtins.AlphaXivClient do
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

  def start_link(_opts \\ []) do
    try do
      headers = load_auth_headers()
      Logger.info("[alphaxiv] Starting MCP client with #{if map_size(headers) > 0, do: "auth token", else: "no auth"}")
      Anubis.Client.start_link(
        name: @client_name,
        transport: {:streamable_http, base_url: @alphaxiv_base_url, mcp_path: @alphaxiv_mcp_path, headers: headers},
        client_info: %{"name" => "VAOS", "version" => "1.0.0"},
        capabilities: %{},
        protocol_version: "2025-06-18"
      )
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
      {:ok, results} -> {:ok, parse_papers(results)}
      error -> error
    end
  end

  @doc "Search papers by keywords"
  def keyword_search(query) do
    case call_tool("full_text_papers_search", %{"query" => query}) do
      {:ok, results} -> {:ok, parse_papers(results)}
      error -> error
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
            {:ok, %{result: result}} -> {:ok, extract_content(result)}
            {:ok, response} -> {:ok, extract_content(response)}
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

  defp parse_papers(results) when is_list(results) do
    Enum.map(results, fn paper ->
      %{
        "title" => Map.get(paper, "title", "Unknown"),
        "abstract" => Map.get(paper, "abstract", "") |> String.slice(0, 200),
        "year" => Map.get(paper, "publicationDate", Map.get(paper, "year", "unknown")) |> to_string() |> String.slice(0, 4),
        "citationCount" => Map.get(paper, "likes", Map.get(paper, "citationCount", 0)),
        "arxivId" => Map.get(paper, "arxivId", "")
      }
    end)
  end
  defp parse_papers(_), do: []

  defp load_auth_headers do
    case File.read(@token_path) do
      {:ok, token} ->
        t = String.trim(token)
        if t != "", do: %{"authorization" => "Bearer " <> t}, else: %{}
      _ -> %{}
    end
  end
end
