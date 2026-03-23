defmodule VAS.Swarm.Decorator do
  @moduledoc """
  Decorator module for automatically handling VAS agent lifecycle.

  ## Example

      defmodule MyAgent do
        use VAS.Swarm.Decorator

        @vas_agent [
          model: "claude-sonnet-4-20250514",
          temperature: 0.7,
          max_tokens: 4096,
          retry_attempts: 3,
          retry_delay: 1000,
          timeout: 30_000
        ]

        def process(input) do
          # Agent logic here
          {:ok, result}
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      @before_compile VAS.Swarm.Decorator
      Module.register_attribute(__MODULE__, :vas_agent, accumulate: false)
      import VAS.Swarm.Decorator, only: [vas_agent: 1]
    end
  end

  defmacro __before_compile__(env) do
    config = Module.get_attribute(env.module, :vas_agent)

    if config do
      quote do
        def __vas_agent_config__ do
          unquote(Macro.escape(config))
        end
      end
    else
      quote do
        def __vas_agent_config__, do: nil
      end
    end
  end

  @doc """
  Defines VAS agent configuration.

  ## Options

    * `:model` - Model identifier (required)
    * `:temperature` - Sampling temperature (0.0 to 1.0, default: 0.7)
    * `:max_tokens` - Maximum tokens in response (default: 4096)
    * `:retry_attempts` - Number of retry attempts (default: 3)
    * `:retry_delay` - Delay between retries in ms (default: 1000)
    * `:timeout` - Request timeout in ms (default: 30_000)

  ## Example

      @vas_agent [
        model: "claude-sonnet-4-20250514",
        temperature: 0.7,
        max_tokens: 4096
      ]
  """
  defmacro vas_agent(config) do
    quote do
      @vas_agent unquote(config)
    end
  end
end
