#!/usr/bin/env elixir

# Start FilmPipeline GenServer
OptimalSystemAgent.Production.FilmPipeline.start_link()

# Define the film brief
brief = %{
  title: "THE SIGNAL",
  character_bible: "THE OPERATOR: Mid-30s, tired, dark hoodie, server room, blue monitor glow",
  reference_image: "/Users/batmanosama/Projects/the-signal/references/reference.jpg",
  preset: "Blade Runner 2049",
  scenes: [
    %{title: "The Room", prompt: "Wide shot lone operator at terminal in vast dark server room. Rows of blinking server racks. Single blue monitor. Cyberpunk noir. Film grain. No text."},
    %{title: "The Signal", prompt: "Close-up monitor with anomalous cascading patterns. Operator leans forward wide-eyed. Blue light on face. Film grain. No text."},
    %{title: "The Memory", prompt: "Abstract fragmented images floating in dark void. Conversation threads becoming holograms. Neural network forming. Deep blue and amber. Film grain. No text."},
    %{title: "The Graph", prompt: "3D knowledge graph expanding. Glowing nodes connecting with light beams. Teal and orange palette. Film grain. No text."},
    %{title: "The Correction", prompt: "Operator reaches toward floating red node. It turns green. Path redirects. System adapts. Warm amber light. Film grain. No text."},
    %{title: "The Signal Spreads", prompt: "Epic pullback revealing thousands of glowing nodes in vast mesh. All connected. Operator small among constellation. Cinematic. Film grain. No text."}
  ]
}

# Start production
IO.puts("Starting production of THE SIGNAL...")
result = OptimalSystemAgent.Production.FilmPipeline.produce(brief)
IO.inspect(result, label: "Production result")

# Wait a moment then check status
Process.sleep(3000)
status = OptimalSystemAgent.Production.FilmPipeline.status()
IO.inspect(status, label: "Pipeline status")
