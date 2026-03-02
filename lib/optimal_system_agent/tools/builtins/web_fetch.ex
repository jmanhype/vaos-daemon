defmodule OptimalSystemAgent.Tools.Builtins.WebFetch do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @max_body_bytes 15_000
  @timeout_ms 15_000

  @impl true
  def name, do: "web_fetch"

  @impl true
  def description, do: "Fetch URL content and extract text. When prompt is provided, uses AI to extract specific information."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "description" => "The URL to fetch"},
        "prompt" => %{"type" => "string", "description" => "What to extract from the page. When provided, an AI model extracts the answer instead of returning raw text."}
      },
      "required" => ["url"]
    }
  end

  @impl true
  def execute(%{"url" => url} = params) do
    prompt = params["prompt"] || "Content"

    if not valid_url?(url) do
      {:error, "Invalid URL: #{url}"}
    else
      ensure_started()

      url_charlist = String.to_charlist(url)
      headers = [{~c"User-Agent", ~c"OSA/1.0"}]
      http_opts = [timeout: @timeout_ms, connect_timeout: 5_000, ssl: ssl_opts()]
      opts = [body_format: :binary]

      case :httpc.request(:get, {url_charlist, headers}, http_opts, opts) do
        {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
          text = body |> strip_html() |> String.slice(0, @max_body_bytes)

          if params["prompt"] && String.length(text) > 100 do
            extract_with_llm(text, params["prompt"], url)
          else
            {:ok, "#{prompt} from #{url}:\n\n#{text}"}
          end

        {:ok, {{_, status, _}, _headers, _body}} ->
          {:error, "HTTP #{status} from #{url}"}

        {:error, reason} ->
          {:error, "Fetch failed: #{inspect(reason)}"}
      end
    end
  end
  def execute(_), do: {:error, "Missing required parameter: url"}

  defp extract_with_llm(text, prompt, url) do
    messages = [
      %{
        role: "system",
        content:
          "You are a precise information extractor. Given web page content, extract exactly what the user asks for. Be concise and accurate. Only return the extracted information, no preamble."
      },
      %{
        role: "user",
        content: "From this web page (#{url}):\n\n#{text}\n\n---\nExtract: #{prompt}"
      }
    ]

    model = Application.get_env(:optimal_system_agent, :utility_model)
    opts = [temperature: 0.1, max_tokens: 2_000]
    opts = if model, do: Keyword.put(opts, :model, model), else: opts

    case Providers.chat(messages, opts) do
      {:ok, %{content: extracted}} when is_binary(extracted) and extracted != "" ->
        {:ok, "Extracted from #{url}:\n\n#{extracted}"}

      _ ->
        {:ok, "#{prompt} from #{url}:\n\n#{text}"}
    end
  rescue
    _ ->
      {:ok, "#{prompt} from #{url}:\n\n#{text}"}
  end

  defp valid_url?(url) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      not private_host?(uri.host)
  end

  defp private_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {10, _, _, _}} -> true
      {:ok, {172, b, _, _}} when b >= 16 and b <= 31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {169, 254, _, _}} -> true
      {:ok, {0, 0, 0, 0}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> host in ["localhost", "0.0.0.0", "::1", "[::1]"]
    end
  end

  defp ensure_started do
    :inets.start()
    :ssl.start()
  rescue
    _ -> :ok
  end

  defp ssl_opts do
    [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 3]
  end

  defp strip_html(body) when is_binary(body) do
    body
    |> String.replace(~r/<script[^>]*>[\s\S]*?<\/script>/i, "")
    |> String.replace(~r/<style[^>]*>[\s\S]*?<\/style>/i, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace(~r/&amp;/, "&")
    |> String.replace(~r/&lt;/, "<")
    |> String.replace(~r/&gt;/, ">")
    |> String.replace(~r/&quot;/, "\"")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
  defp strip_html(_), do: ""
end
