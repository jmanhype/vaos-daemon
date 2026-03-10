defmodule OptimalSystemAgent.Vault.Supervisor do
  @moduledoc """
  Supervises Vault stateful processes: FactStore and Observer.
  """
  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Initialize vault directory structure
    OptimalSystemAgent.Vault.Store.init()

    children = [
      OptimalSystemAgent.Vault.FactStore,
      OptimalSystemAgent.Vault.Observer
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
