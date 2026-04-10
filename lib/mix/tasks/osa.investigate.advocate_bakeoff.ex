defmodule Mix.Tasks.Osa.Investigate.AdvocateBakeoff do
  @moduledoc """
  Run a bounded advocate provider/model bakeoff on the exact investigate prompts.

  Usage:

      mix osa.investigate.advocate_bakeoff
      mix osa.investigate.advocate_bakeoff --topic "assess whether caffeine improves endurance"
      mix osa.investigate.advocate_bakeoff --lane openai:gpt-4o-mini --lane zhipu:glm-4.5-flash
  """

  use Mix.Task

  alias Daemon.Tools.InvestigateAdvocateBakeoff

  @shortdoc "Profile investigate advocate lanes"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          topic: :string,
          lane: :keep,
          timeout_ms: :integer,
          max_lanes: :integer,
          depth: :string,
          output: :string
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    if is_nil(System.get_env("DAEMON_HTTP_PORT")) do
      System.put_env("DAEMON_HTTP_PORT", "0")
    end

    Mix.Task.run("app.start")
    Daemon.Onboarding.auto_configure()

    if MiosaProviders.Registry.provider_configured?(:ollama) do
      MiosaProviders.Ollama.auto_detect_model()
      Daemon.Agent.Tier.detect_ollama_tiers()
    end

    topic = Keyword.get(opts, :topic, InvestigateAdvocateBakeoff.default_topic())

    result =
      InvestigateAdvocateBakeoff.run_topic(
        topic,
        lane: Keyword.get_values(opts, :lane),
        timeout_ms: Keyword.get(opts, :timeout_ms, 7_500),
        max_lanes: Keyword.get(opts, :max_lanes, 3),
        depth: Keyword.get(opts, :depth, "standard")
      )

    output_path = Keyword.get(opts, :output, default_output_path())
    File.write!(output_path, Jason.encode!(result, pretty: true))

    print_summary(result)
    Mix.shell().info("Saved advocate bakeoff: #{output_path}")
    System.halt(0)
  end

  defp default_output_path do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(System.tmp_dir!(), "investigate-advocate-bakeoff-#{stamp}.json")
  end

  defp print_summary(result) do
    Mix.shell().info(
      "Topic: #{result.topic} | evidence_plan=#{result.evidence_plan_mode} | papers=#{result.paper_count}"
    )

    Enum.each(result.lanes, fn lane ->
      Mix.shell().info(
        "* #{lane.lane.label}: success=#{lane.success_sides}/2 sourced=#{lane.sourced_items} " <>
          "parsed=#{lane.parsed_items} latency=#{lane.total_latency_ms}ms " <>
          "score=#{lane.selection_score} viable=#{lane.viable}"
      )
    end)

    case result.winner do
      nil ->
        Mix.shell().error("No viable lane")

      winner ->
        Mix.shell().info("Winner: #{winner.lane.label}")
    end
  end
end
