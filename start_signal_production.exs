# Script to start THE SIGNAL film production
# Usage: elixir -r start_signal_production.exs

# Start the application with production enabled
Application.put_env(:optimal_system_agent, :production_enabled, true)

Code.append_path("_build/dev/lib/optimal_system_agent/ebin")
Code.append_path("_build/dev/lib/phoenix_pubsub/ebin")
Code.append_path("_build/dev/lib/jason/ebin")
Code.append_path("_build/dev/lib/req/ebin")
Code.append_path("_build/dev/lib/bandit/ebin")
Code.append_path("_build/dev/lib/plug/ebin")
Code.append_path("_build/dev/lib/ecto/ebin")
Code.append_path("_build/dev/lib/ecto_sql/ebin")
Code.append_path("_build/dev/lib/plug/ebin")

# Start the application
{:ok, _pid} = Application.ensure_all_started(:optimal_system_agent)

# Give it a moment to start the supervision tree
Process.sleep(2000)

# Define the production brief
brief = %{
  title: "THE SIGNAL",
  character_bible: "THE OPERATOR - Mid-30s, tired eyes, dark hoodie, server room blue monitor glow",
  preset: "Blade Runner 2049",
  reference_image: "/Users/batmanosama/Projects/the-signal/references/reference.jpg",
  scenes: [
    %{
      title: "The Room",
      prompt: "Wide shot, operator at terminal, dark server room, blinking LEDs, cyberpunk noir, film grain"
    },
    %{
      title: "The Signal",
      prompt: "Close-up monitor, anomalous patterns, operator leans forward, blue light, film grain"
    },
    %{
      title: "The Memory",
      prompt: "Fragmented images floating in dark space, neural network visualization, blue amber, film grain"
    },
    %{
      title: "The Graph",
      prompt: "3D knowledge graph expanding, glowing nodes, teal orange, film grain"
    },
    %{
      title: "The Correction",
      prompt: "Operator reaches toward node, changes red to green, system adapts, amber light, film grain"
    },
    %{
      title: "The Signal Spreads",
      prompt: "Epic wide pullback, thousands of nodes mesh network, all connected, cinematic, film grain"
    }
  ]
}

# Start production
IO.puts("🎬 Starting THE SIGNAL film production...")
IO.puts("   Title: #{brief.title}")
IO.puts("   Preset: #{brief.preset}")
IO.puts("   Scenes: #{length(brief.scenes)}")
IO.puts("   Reference: #{brief.reference_image}")
IO.puts("")

case OptimalSystemAgent.Production.FilmPipeline.produce(brief) do
  :ok ->
    IO.puts("✓ Production started successfully!")
    IO.puts("  Check status with: OptimalSystemAgent.Production.FilmPipeline.status()")
  {:error, reason} ->
    IO.puts("✗ Failed to start production: #{inspect(reason)}")
end
