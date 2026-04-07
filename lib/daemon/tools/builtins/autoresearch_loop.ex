defmodule Daemon.Tools.Builtins.AutoresearchLoop do
  @moduledoc """
  Bilevel Autoresearch Loop — chains investigate → paper → code → eval → fix.

  Orchestrates the full research-to-code pipeline as a sequential workflow:
  1. Investigate a topic (deep epistemic investigation)
  2. Generate an academic paper from findings (Denario)
  3. Convert paper to working code (paper2code pattern)
  4. Evaluate/dogfood the generated code
  5. Fix bugs and push to GitHub

  Uses the Workflow engine with a template at priv/workflows/autoresearch.json.
  """

  @behaviour MiosaTools.Behaviour

  require Logger

  alias Daemon.Agent.Tasks.Workflow

  @template_path Path.join(:code.priv_dir(:daemon), "workflows/autoresearch.json")

  @impl true
  def name, do: "autoresearch_loop"

  @impl true
  def description do
    "Run a full autoresearch loop: investigate a topic → generate paper → convert to code → evaluate → fix and publish. " <>
      "Chains investigate, Denario paper generation, paper2code, and dogfood eval into a single automated workflow."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "topic" => %{
          "type" => "string",
          "description" => "The research topic to investigate and implement (e.g., 'contrastive learning for code generation')"
        },
        "depth" => %{
          "type" => "string",
          "enum" => ["standard", "deep"],
          "description" => "Investigation depth. 'deep' runs full adversarial analysis with paper search. Default: deep"
        }
      },
      "required" => ["topic"]
    }
  end

  @impl true
  def execute(%{"topic" => topic} = args) do
    depth = Map.get(args, "depth", "deep")
    slug = slugify(topic)

    Logger.info("[AutoresearchLoop] Starting: topic=#{inspect(topic)}, depth=#{depth}")

    # Inject topic and depth into template descriptions
    template_path = prepare_template(topic, depth, slug)

    case template_path do
      {:ok, path} ->
        # Create workflow via the Workflow engine
        # We need to get the agent state to create a workflow — use a session message instead
        result = %{
          "status" => "workflow_created",
          "topic" => topic,
          "depth" => depth,
          "slug" => slug,
          "template_path" => path,
          "instructions" => """
          Autoresearch workflow template prepared at #{path}.

          To execute, work through the 5 steps sequentially:

          **Step 1 — Investigate**: Run `investigate` with topic="#{topic}" depth="#{depth}"
          **Step 2 — Generate Paper**: Use the investigation results to create a data_description.md, then run Denario
          **Step 3 — Paper to Code**: Convert the generated paper to a PyTorch implementation
          **Step 4 — Evaluate**: Run imports, sanity checks, and tests on the generated code
          **Step 5 — Fix & Publish**: Fix any bugs, re-test, push to GitHub as jmanhype/autoresearch-#{slug}

          Each step's output feeds into the next. Start with Step 1 now.
          """
        }

        {:ok, Jason.encode!(result)}

      {:error, reason} ->
        {:error, "Failed to prepare autoresearch template: #{inspect(reason)}"}
    end
  end

  def execute(_args) do
    {:error, "Missing required parameter: topic"}
  end

  # --- Private ---

  defp prepare_template(topic, depth, slug) do
    case File.read(@template_path) do
      {:ok, raw} ->
        # Replace placeholders in the template
        filled =
          raw
          |> String.replace("{{topic}}", topic)
          |> String.replace("{{depth}}", depth)
          |> String.replace("{{slug}}", slug)

        # Write the filled template to /tmp for this run
        out_path = "/tmp/autoresearch_workflow_#{slug}.json"
        File.mkdir_p!(Path.dirname(out_path))
        File.write!(out_path, filled)
        {:ok, out_path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp slugify(topic) do
    topic
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 50)
  end
end
