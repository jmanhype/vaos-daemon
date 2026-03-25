defmodule Daemon.Tools.CachedExecutor do
  @moduledoc """
  Wraps tool execution with an ETS-backed cache.

  On cache hit, returns the stored result immediately.
  On cache miss, calls `module.execute(params)` and stores the result.

  Options:
  - `bypass: true` — skip cache lookup and storage for this call
  - `ttl_ms: integer` — custom TTL (default: 60_000 ms)
  """

  alias Daemon.Tools.Cache

  @doc """
  Generate a deterministic cache key from a module and params map.
  Params are sorted by key to ensure consistent hashing.
  """
  def cache_key(module, params) when is_map(params) do
    sorted = params |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    :erlang.phash2({module, sorted})
  end

  def cache_key(module, params) do
    :erlang.phash2({module, params})
  end

  @doc """
  Execute a tool module with caching.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def execute(module, params, opts \\ []) do
    bypass = Keyword.get(opts, :bypass, false)
    ttl_ms = Keyword.get(opts, :ttl_ms, 60_000)

    if bypass do
      module.execute(params)
    else
      key = cache_key(module, params)

      case Cache.get(key) do
        {:ok, cached} ->
          {:ok, cached}

        _ ->
          case module.execute(params) do
            {:ok, result} = ok ->
              Cache.put(key, result, ttl_ms)
              ok

            error ->
              error
          end
      end
    end
  end
end
