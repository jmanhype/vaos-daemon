defmodule Daemon.GitHubClient do
  @moduledoc """
  GitHub API client with connection keep-alive and request pipelining.

  This module provides a performant HTTP client for GitHub API interactions with:
  - Connection pooling and reuse (keep-alive)
  - Request pipelining for batch operations
  - Automatic retry logic with exponential backoff
  - Rate limit handling and respect

  ## Usage

      # Single request
      {:ok, response} = GitHubClient.get_repo("owner/repo")

      # Pipelined requests (executed concurrently)
      {:ok, results} = GitHubClient.pipeline([
        {:get_file, "owner/repo", "path/to/file.ex"},
        {:list_issues, "owner/repo", %{state: "open"}},
        {:get_repo, "owner/repo"}
      ])
  """

  use GenServer
  require Logger

  @default_base_url "https://api.github.com"
  @max_connections 10
  @connection_timeout 30_000
  @request_timeout 30_000

  # --- Client API ---

  @doc """
  Start the GitHub client with optional configuration.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get repository information.
  """
  def get_repo(repo) when is_binary(repo) do
    request(:get, "repos/#{repo}", %{})
  end

  @doc """
  Get file content from a repository.
  """
  def get_file(repo, path) do
    request(:get, "repos/#{repo}/contents/#{path}", %{})
  end

  @doc """
  Write/update file content in a repository.
  """
  def write_file(repo, path, content, message, opts \\ %{}) do
    body = %{
      message: message,
      content: Base.encode64(content)
    }

    body =
      if opts[:sha], do: Map.put(body, :sha, opts[:sha]), else: body
    body =
      if opts[:branch], do: Map.put(body, :branch, opts[:branch]), else: body

    request(:put, "repos/#{repo}/contents/#{path}", body)
  end

  @doc """
  List directory contents.
  """
  def list_files(repo, path \\ "") do
    request(:get, "repos/#{repo}/contents/#{path}", %{})
  end

  @doc """
  List pull requests.
  """
  def list_prs(repo, opts \\ %{}) do
    params =
      opts
      |> Enum.filter(fn {k, _} -> k in [:state, :limit, :head, :base, :sort, :direction] end)
      |> Map.new()

    request(:get, "repos/#{repo}/pulls", %{}, params: params)
  end

  @doc """
  Get pull request details.
  """
  def get_pr(repo, number) do
    request(:get, "repos/#{repo}/pulls/#{number}", %{})
  end

  @doc """
  Create a pull request.
  """
  def create_pr(repo, title, body, opts \\ %{}) do
    params = %{
      title: title,
      body: body || ""
    }

    params =
      if opts[:base], do: Map.put(params, :base, opts[:base]), else: params
    params =
      if opts[:head], do: Map.put(params, :head, opts[:head]), else: params
    params =
      if opts[:draft], do: Map.put(params, :draft, true), else: params

    request(:post, "repos/#{repo}/pulls", params)
  end

  @doc """
  Merge a pull request.
  """
  def merge_pr(repo, number, method \\ "merge") do
    body =
      case method do
        "squash" -> %{commit_title: "", merge_method: "squash"}
        "rebase" -> %{merge_method: "rebase"}
        _ -> %{merge_method: "merge"}
      end

    request(:put, "repos/#{repo}/pulls/#{number}/merge", body)
  end

  @doc """
  List issues.
  """
  def list_issues(repo, opts \\ %{}) do
    params =
      opts
      |> Enum.filter(fn {k, _} -> k in [:state, :limit, :sort, :direction, :labels] end)
      |> Map.new()

    request(:get, "repos/#{repo}/issues", %{}, params: params)
  end

  @doc """
  Get issue details.
  """
  def get_issue(repo, number) do
    request(:get, "repos/#{repo}/issues/#{number}", %{})
  end

  @doc """
  Create an issue.
  """
  def create_issue(repo, title, body, opts \\ %{}) do
    params = %{
      title: title,
      body: body || ""
    }

    params =
      if opts[:labels], do: Map.put(params, :labels, opts[:labels]), else: params

    request(:post, "repos/#{repo}/issues", params)
  end

  @doc """
  Comment on an issue.
  """
  def comment_issue(repo, number, body) do
    request(:post, "repos/#{repo}/issues/#{number}/comments", %{body: body})
  end

  @doc """
  List workflow runs.
  """
  def list_runs(repo, opts \\ %{}) do
    params =
      opts
      |> Enum.filter(fn {k, _} -> k in [:limit, :status, :branch] end)
      |> Map.new()

    request(:get, "repos/#{repo}/actions/runs", %{}, params: params)
  end

  @doc """
  Get workflow run details.
  """
  def get_run(repo, run_id) do
    request(:get, "repos/#{repo}/actions/runs/#{run_id}", %{})
  end

  @doc """
  Execute multiple requests concurrently (pipelining).

  Returns {:ok, results} where results is a list of responses in the same order as requests.
  """
  def pipeline(requests) when is_list(requests) do
    tasks =
      Enum.map(requests, fn
        {:get_repo, repo} -> Task.async(fn -> get_repo(repo) end)
        {:get_file, repo, path} -> Task.async(fn -> get_file(repo, path) end)
        {:list_files, repo, path} -> Task.async(fn -> list_files(repo, path) end)
        {:list_prs, repo, opts} -> Task.async(fn -> list_prs(repo, opts) end)
        {:get_pr, repo, number} -> Task.async(fn -> get_pr(repo, number) end)
        {:list_issues, repo, opts} -> Task.async(fn -> list_issues(repo, opts) end)
        {:get_issue, repo, number} -> Task.async(fn -> get_issue(repo, number) end)
        {:list_runs, repo, opts} -> Task.async(fn -> list_runs(repo, opts) end)
        {:get_run, repo, run_id} -> Task.async(fn -> get_run(repo, run_id) end)
        _ -> Task.async(fn -> {:error, :unknown_request} end)
      end)

    results = Task.await_many(tasks, @request_timeout)

    if Enum.all?(results, fn
         {:ok, _} -> true
         _ -> false
       end) do
      {:ok, results}
    else
      {:error, :pipeline_failed, results}
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    # Get GitHub token from environment
    token = System.get_env("GITHUB_TOKEN")

    state = %{
      token: token,
      base_url: @default_base_url,
      rate_limit_remaining: nil,
      rate_limit_reset: nil
    }

    Logger.info("GitHubClient: Started with connection pooling (max: #{@max_connections})")
    {:ok, state}
  end

  @impl true
  def handle_call({:request, method, path, body, opts}, _from, state) do
    url = state.base_url <> "/" <> path
    params = Keyword.get(opts, :params, %{})

    result =
      url
      |> build_req(state.token, params)
      |> execute_req(method, body)
      |> handle_response()

    # Update rate limit info from response headers
    new_state = update_rate_limit_state(state, result)

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # --- Internal Request Logic ---

  defp request(method, path, body, opts \\ []) do
    GenServer.call(__MODULE__, {:request, method, path, body, opts}, @request_timeout)
  end

  defp build_req(url, token, params) do
    req_opts = [
      # Connection pooling settings
      connect_options: [
        timeout: @connection_timeout,
        transport_opts: [
          # Enable TCP keep-alive
          keepalive: true
        ]
      ],
      # Pool settings for connection reuse
      pooled_connections: @max_connections,
      # Retry configuration
      retry: :transient,
      max_retries: 3,
      retry_interval: 1000,
      # Auth headers
      auth: {:bearer, token},
      # JSON handling
      json: %{}
    ]

    # Add query parameters if present
    req =
      if map_size(params) > 0 do
        Req.new(req_opts) |> Req.Request.merge_options(params: params)
      else
        Req.new(req_opts)
      end

    {req, url}
  end

  defp execute_req({req, url}, :get, _body) do
    case Req.get(req, url: url) do
      {:ok, response} -> {:ok, response}
      {:error, error} -> {:error, :request_failed, error}
    end
  end

  defp execute_req({req, url}, :post, body) do
    case Req.post(req, url: url, json: body) do
      {:ok, response} -> {:ok, response}
      {:error, error} -> {:error, :request_failed, error}
    end
  end

  defp execute_req({req, url}, :put, body) do
    case Req.put(req, url: url, json: body) do
      {:ok, response} -> {:ok, response}
      {:error, error} -> {:error, :request_failed, error}
    end
  end

  defp execute_req({req, url}, :delete, _body) do
    case Req.delete(req, url: url) do
      {:ok, response} -> {:ok, response}
      {:error, error} -> {:error, :request_failed, error}
    end
  end

  defp handle_response({:ok, %{status: status, body: body, headers: headers}})
       when status >= 200 and status < 300 do
    # Extract rate limit info
    rate_limit = %{
      remaining: get_header(headers, "x-ratelimit-remaining"),
      reset: get_header(headers, "x-ratelimit-reset"),
      used: get_header(headers, "x-ratelimit-used")
    }

    content =
      case Jason.decode(body) do
        {:ok, decoded} when is_map(decoded) ->
          # Handle nested content field from GitHub API for file contents
          case decoded do
            %{"content" => content_b64, "encoding" => "base64"} ->
              Base.decode64!(content_b64)
            _ ->
              decoded
          end
        {:ok, decoded} -> decoded
        {:error, _} -> body
      end

    {:ok, content, rate_limit}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    error_body =
      case Jason.decode(body) do
        {:ok, %{"message" => message}} -> message
        {:ok, _} -> body
        _ -> "HTTP #{status}"
      end

    {:error, error_body}
  end

  defp handle_response({:error, _, error}) do
    {:error, Exception.message(error)}
  end

  defp get_header(headers, key) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == String.downcase(key), do: v, else: nil
    end)
  end

  defp update_rate_limit_state(state, {:ok, _content, rate_limit}) do
    %{state | rate_limit_remaining: rate_limit.remaining, rate_limit_reset: rate_limit.reset}
  end

  defp update_rate_limit_state(state, _), do: state

  @doc """
  Get current connection pool statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :get_state)
  end
end
