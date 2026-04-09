defmodule Mix.Tasks.Osa.Investigate.Overlap do
  @moduledoc """
  Run traced investigate samples and summarize cross-side verifier overlap.

  Usage:

      mix osa.investigate.overlap
      mix osa.investigate.overlap --topic "moderate alcohol consumption has health benefits"
      mix osa.investigate.overlap --topics-file topics.txt --output /tmp/overlap.json
  """

  use Mix.Task

  alias Daemon.Tools.InvestigateOverlapProfiler

  @shortdoc "Profile cross-side investigate verifier overlap"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          topic: :keep,
          topics_file: :string,
          output: :string,
          trace_label: :string,
          depth: :string
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    # This task only needs the investigation pipeline, not the public HTTP port.
    # Default to an ephemeral listener so profiling can run alongside a live daemon.
    if is_nil(System.get_env("DAEMON_HTTP_PORT")) do
      System.put_env("DAEMON_HTTP_PORT", "0")
    end

    Mix.Task.run("app.start")
    Daemon.Onboarding.auto_configure()

    if Application.get_env(:daemon, :default_provider) == :ollama do
      MiosaProviders.Ollama.auto_detect_model()
      Daemon.Agent.Tier.detect_ollama_tiers()
    end

    topics = topics_from_opts(opts)
    trace_label = Keyword.get(opts, :trace_label, "overlap-profile")
    depth = Keyword.get(opts, :depth, "standard")

    Mix.shell().info("Profiling #{length(topics)} investigate runs...")

    result =
      InvestigateOverlapProfiler.run_topics(
        topics,
        trace_label: trace_label,
        depth: depth
      )

    output_path = Keyword.get(opts, :output, default_output_path())

    payload = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      topics: topics,
      result: result
    }

    File.write!(output_path, Jason.encode!(payload, pretty: true))

    Enum.each(result.topics, &print_topic_result/1)
    print_summary(result.summary)

    Mix.shell().info("Saved overlap profile: #{output_path}")
    System.halt(0)
  end

  defp topics_from_opts(opts) do
    cli_topics = Keyword.get_values(opts, :topic)
    file_topics = load_topics_file(Keyword.get(opts, :topics_file))

    topics =
      (cli_topics ++ file_topics)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if topics == [] do
      InvestigateOverlapProfiler.default_topics()
    else
      topics
    end
  end

  defp load_topics_file(nil), do: []

  defp load_topics_file(path) do
    path
    |> File.read!()
    |> String.split("\n")
  end

  defp default_output_path do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(System.tmp_dir!(), "investigate-overlap-profile-#{stamp}.json")
  end

  defp print_topic_result(%{status: "ok"} = snapshot) do
    Mix.shell().info(
      "* #{snapshot.topic}: overlap=#{snapshot.cross_side_overlap_items}/#{snapshot.cross_side_unique_llm_items} " <>
        "rate=#{format_pct(snapshot.cross_side_overlap_rate)} trace=#{snapshot.trace_path || "n/a"}"
    )
  end

  defp print_topic_result(snapshot) do
    Mix.shell().error("* #{snapshot.topic}: #{snapshot.status} #{Map.get(snapshot, :error, "")}")
  end

  defp print_summary(summary) do
    Mix.shell().info(
      "Summary: zero-overlap=#{summary.zero_overlap_runs}/#{summary.run_count} " <>
        "aggregate_rate=#{format_pct(summary.aggregate_cross_side_overlap_rate)} " <>
        "avg_rate=#{format_pct(summary.average_cross_side_overlap_rate)}"
    )

    if summary.top_overlap_examples != [] do
      Mix.shell().info("Top shared examples:")

      Enum.each(summary.top_overlap_examples, fn example ->
        Mix.shell().info(
          "  - runs=#{example.count_runs} paper=#{example.paper_ref} claim=#{example.claim}"
        )
      end)
    end
  end

  defp format_pct(value) when is_number(value), do: "#{Float.round(value * 100, 1)}%"
  defp format_pct(_value), do: "0.0%"
end
