#!/usr/bin/env elixir

# Query knowledge graph for all triples with predicate vaos:language

# Start the vaos_knowledge application
Application.ensure_all_started(:vaos_knowledge)

# Open the knowledge store
{:ok, _store} = Vaos.Knowledge.open("osa_default")

# Query for all triples with predicate vaos:language
results = Vaos.Knowledge.query("osa_default", [predicate: "vaos:language"])

# Format and display results
case results do
  {:ok, []} ->
    IO.puts("No triples found with predicate vaos:language")

  {:ok, triples} ->
    IO.puts("Found #{length(triples)} triples with predicate vaos:language:")
    Enum.each(triples, fn {subject, predicate, object} ->
      IO.puts("  (#{subject}) --[#{predicate}]--> (#{object})")
    end)

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end
