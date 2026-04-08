defmodule Daemon.Investigation.SteeringTest do
  use ExUnit.Case, async: true

  alias Daemon.Investigation.Steering

  test "trial steering for low_verification includes actionable verification repair guidance" do
    steering = Steering.trial("meta_pivot_requested", "low_verification")

    assert steering =~ "pivot pass"
    assert steering =~ "quote the EXACT sentence from the abstract"
    assert steering =~ "analytical inference"
  end

  test "quality steering for low_verification reuses the same corrective guidance" do
    steering =
      Steering.quality(%{
        bottleneck: :low_verification,
        avg_verification_rate: 0.27
      })

    assert steering =~ "27.0% verification rate"
    assert steering =~ "quote the EXACT sentence from the abstract"
    assert steering =~ "analytical inference"
  end
end
