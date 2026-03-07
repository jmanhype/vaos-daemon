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
end
