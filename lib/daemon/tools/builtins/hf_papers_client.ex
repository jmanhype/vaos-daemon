defmodule Daemon.Tools.Builtins.HFPapersClient do
  @moduledoc """
  HuggingFace Daily Papers search client.
  Uses the public HF Hub API to search ML/AI papers from arXiv.
  No authentication required.
  """
  require Logger

  @search_url "https://huggingface.co/api/papers/search"
  @timeout 15_000

  @doc """
  Search HuggingFace papers by query string.
  Returns {:ok, papers} where papers are string-keyed maps matching investigate.ex format.
  """
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    url = "#{@search_url}?q=#{URI.encode_www_form(query)}&limit=#{limit}"

    case Req.get(url, receive_timeout: @timeout, connect_options: [timeout: 5_000]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        papers = Enum.map(body, &normalize_paper/1)
        Logger.debug("[hf_papers] Search '#{query}' returned #{length(papers)} papers")
        {:ok, papers}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[hf_papers] API returned #{status}: #{inspect(body) |> String.slice(0, 200)}")
        {:error, :api_error}

      {:error, reason} ->
        Logger.warning("[hf_papers] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[hf_papers] Exception: #{Exception.message(e)}")
      {:error, :exception}
  end

  defp normalize_paper(%{"paper" => paper}) do
    authors = paper
    |> Map.get("authors", [])
    |> Enum.map(fn a -> Map.get(a, "name", "") end)
    |> Enum.reject(&(&1 == ""))

    year = case Map.get(paper, "publishedAt") do
      nil -> "unknown"
      date -> date |> String.slice(0, 4)
    end

    arxiv_id = Map.get(paper, "id", "")

    %{
      "title" => clean_title(Map.get(paper, "title", "Unknown")),
      "abstract" => Map.get(paper, "summary", "") |> String.replace("\n", " ") |> String.trim(),
      "year" => year,
      "citation_count" => Map.get(paper, "upvotes", 0),
      "citationCount" => Map.get(paper, "upvotes", 0),
      "source" => "huggingface",
      "authors" => Enum.join(authors, ", "),
      "paper_id" => arxiv_id,
      "url" => if(arxiv_id != "", do: "https://arxiv.org/abs/#{arxiv_id}", else: ""),
      "doi" => nil,
      "publicationTypes" => [],
      "arxivId" => arxiv_id
    }
  end

  # Handle unexpected format (paper not nested under "paper" key)
  defp normalize_paper(paper) when is_map(paper) do
    normalize_paper(%{"paper" => paper})
  end

  defp clean_title(title) do
    title
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
