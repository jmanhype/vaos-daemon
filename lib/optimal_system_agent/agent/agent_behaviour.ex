defmodule OptimalSystemAgent.Agent.AgentBehaviour do
  @moduledoc "Behaviour contract for OSA agent definitions."

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback tier() :: :elite | :specialist | :utility
  @callback role() :: atom()
  @callback system_prompt() :: String.t()
  @callback skills() :: [String.t()]
  @callback triggers() :: [String.t()]
  @callback territory() :: [String.t()]
  @callback escalate_to() :: String.t() | nil

  @doc "Pure agent logic — process a message and return a directive or string."
  @callback handle(message :: String.t(), context :: map()) ::
              {:ok, OptimalSystemAgent.Agent.Directive.t() | String.t()}
              | {:error, term()}

  @doc "Optional: pre-processing hook before the main handle."
  @callback before_handle(message :: String.t(), context :: map()) ::
              {:ok, String.t()} | {:skip, String.t()}

  @doc "Optional: post-processing hook after handle returns."
  @callback after_handle(result :: term(), context :: map()) :: term()

  # Make them optional so existing agents don't break
  @optional_callbacks [handle: 2, before_handle: 2, after_handle: 2]
end
