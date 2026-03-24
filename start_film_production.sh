#!/bin/bash
cd /Users/batmanosama/vas-swarm

# Enable production mode
export OSA_PRODUCTION_ENABLED=true

# Start IEx with the production brief
elixir -e "
Application.put_env(:optimal_system_agent, :production_enabled, true)

# Append ebin paths
Code.append_path('_build/dev/lib/optimal_system_agent/ebin')
Code.append_path('_build/dev/lib/phoenix_pubsub/ebin')
Code.append_path('_build/dev/lib/jason/ebin')
Code.append_path('_build/dev/lib/req/ebin')
Code.append_path('_build/dev/lib/bandit/ebin')
Code.append_path('_build/dev/lib/plug/ebin')

# Start the application
{:ok, _pid} = Application.ensure_all_started(:optimal_system_agent)

# Give it a moment to start
Process.sleep(2000)

# Define the brief
brief = %{
  title: \"THE SIGNAL\",
  character_bible: \"THE OPERATOR: Mid-30s, tired, dark hoodie, server room, blue monitor glow\",
  reference_image: \"/Users/batmanosama/Projects/the-signal/references/reference.jpg\",
  preset: \"Blade Runner 2049\",
  scenes: [
    %{title: \"The Room\", prompt: \"Wide shot lone operator at terminal in vast dark server room. Rows of blinking server racks. Single blue monitor. Cyberpunk noir. Film grain. No text.\"},
    %{title: \"The Signal\", prompt: \"Close-up monitor with anomalous cascading patterns. Operator leans forward wide-eyed. Blue light on face. Film grain. No text.\"},
    %{title: \"The Memory\", prompt: \"Abstract fragmented images floating in dark void. Conversation threads becoming holograms. Neural network forming. Deep blue and amber. Film grain. No text.\"},
    %{title: \"The Graph\", prompt: \"3D knowledge graph expanding. Glowing nodes connecting with light beams. Teal and orange palette. Film grain. No text.\"},
    %{title: \"The Correction\", prompt: \"Operator reaches toward floating red node. It turns green. Path redirects. System adapts. Warm amber light. Film grain. No text.\"},
    %{title: \"The Signal Spreads\", prompt: \"Epic pullback revealing thousands of glowing nodes in vast mesh. All connected. Operator small among constellation. Cinematic. Film grain. No text.\"}
  ]
}

IO.puts(\"🎬 Producing film: #{brief.title}\")
IO.puts(\"📖 Scenes: #{length(brief.scenes)}\")
IO.puts(\"🎨 Preset: #{brief.preset}\")

# Call the FilmPipeline
case GenServer.call(OptimalSystemAgent.Production.FilmPipeline, {:produce, brief}, 60000) do
  :ok ->
    IO.puts(\"\n✅ Film production started!\")
    IO.puts(\"Check status with: FilmPipeline.status()\")

  {:error, reason} ->
    IO.puts(\"\n❌ Film production failed: #{inspect(reason)}\")
end

# Keep the process alive for async operations
Process.sleep(5000)
"
