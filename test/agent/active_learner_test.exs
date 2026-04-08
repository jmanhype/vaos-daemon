defmodule Daemon.Agent.ActiveLearnerTest do
  use ExUnit.Case, async: false

  alias Daemon.Agent.ActiveLearner

  setup do
    original = Application.get_env(:daemon, :active_learner_chain_enabled, :__missing__)

    on_exit(fn ->
      case original do
        :__missing__ -> Application.delete_env(:daemon, :active_learner_chain_enabled)
        value -> Application.put_env(:daemon, :active_learner_chain_enabled, value)
      end
    end)

    :ok
  end

  test "chain_enabled?/0 defaults to true when unset" do
    Application.delete_env(:daemon, :active_learner_chain_enabled)

    assert ActiveLearner.chain_enabled?()
  end

  test "chain_enabled?/0 honors runtime config overrides" do
    Application.put_env(:daemon, :active_learner_chain_enabled, false)
    refute ActiveLearner.chain_enabled?()

    Application.put_env(:daemon, :active_learner_chain_enabled, true)
    assert ActiveLearner.chain_enabled?()
  end
end
