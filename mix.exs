defmodule Daemon.MixProject do
  use Mix.Project

  @version "VERSION" |> File.read!() |> String.trim()
  @source_url "https://github.com/Miosa-osa/OSA"

  def project do
    [
      app: :daemon,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      name: "Daemon",
      description: "Signal Theory-optimized proactive AI agent. Run locally. Elixir/OTP.",
      source_url: @source_url,
      docs: docs(),
      rustler_crates: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {Daemon.Application, []}
    ]
  end

  defp deps do
    [
      # Event routing — compiled Erlang bytecode dispatch (BEAM speed)
      # https://github.com/robertohluna/goldrush (fork of extend/goldrush)
      {:goldrush, github: "robertohluna/goldrush", branch: "main", override: true},

      # HTTP client for LLM APIs
      {:req, "~> 0.5"},

      # JSON
      {:jason, "~> 1.4"},

      # JSON Schema validation (tool argument validation)
      {:ex_json_schema, "~> 0.11"},

      # PubSub for internal event fan-out (standalone, no Phoenix framework)
      {:phoenix_pubsub, "~> 2.1"},

      # YAML parsing (skills, config)
      {:yaml_elixir, "~> 2.9"},

      # HTTP server for webhooks + MCP (lightweight, no Phoenix)
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},

      # Database — Ecto + SQLite3
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},

      # Platform database — PostgreSQL for multi-tenant data
      {:postgrex, "~> 0.19"},

      # Password hashing (only needed for platform multi-tenant auth in prod)
      {:bcrypt_elixir, "~> 3.0", only: :prod, optional: true},

      # AMQP — RabbitMQ publisher for Go worker events (optional)
      {:amqp, "~> 4.1", optional: true},

      # gRPC client for VAS-Swarm Kernel communication (optional)
      {:grpc, "~> 0.7", optional: true},
      {:gun, "~> 2.0", optional: true},

      # Telemetry
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},

      # OTP 28: rustler removed — nif.ex uses pure Elixir fallbacks
      # {:rustler, "~> 0.37", optional: true}

      # Epistemic ledger — AIEQ claim tracking
      {:vaos_ledger, path: "../vaos-ledger"},

      # AlphaXiv MCP client — BEAM-native MCP SDK
      {:anubis_mcp, "~> 1.0"},

      # Knowledge graph — triple store with SPARQL and OWL 2 RL reasoning
      {:vaos_knowledge, path: "../vaos-knowledge"},

      # miosa_* packages are not standalone deps — their implementations live
      # in this repo. Shim modules in lib/miosa/ satisfy all call sites.
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "compile"],
      chat: ["run --no-halt -e 'Daemon.Channels.CLI.start()'"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end

  defp releases do
    [
      daemon: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, &copy_go_tokenizer/1, &copy_daemon_wrapper/1],
        rel_templates_path: "rel"
      ]
    ]
  end

  # Copy the pre-built Go tokenizer binary into the release's priv directory.
  # The binary must be compiled before `mix release` (CI does this in a prior step).
  defp copy_go_tokenizer(release) do
    src = Path.join(["priv", "go", "tokenizer", "daemon-tokenizer"])

    dst_dir =
      Path.join([
        release.path,
        "lib",
        "daemon-#{@version}",
        "priv",
        "go",
        "tokenizer"
      ])

    if File.exists?(src) do
      File.mkdir_p!(dst_dir)
      File.cp!(src, Path.join(dst_dir, "daemon-tokenizer"))
    end

    release
  end

  # Install the `daemon` CLI wrapper alongside the release binary.
  # Renames the generated release script (bin/daemon → bin/daemon_release)
  # and copies in our wrapper that dispatches subcommands via `eval`.
  defp copy_daemon_wrapper(release) do
    bin_dir = Path.join(release.path, "bin")
    release_bin = Path.join(bin_dir, "daemon")
    renamed_bin = Path.join(bin_dir, "daemon_release")

    # Rename the release's own boot script
    if File.exists?(release_bin) do
      File.rename!(release_bin, renamed_bin)
    end

    # Write our wrapper
    wrapper = Path.join(bin_dir, "daemon")
    File.write!(wrapper, daemon_wrapper_script())
    File.chmod!(wrapper, 0o755)

    release
  end

  defp daemon_wrapper_script do
    ~S"""
    #!/bin/sh
    # daemon — CLI wrapper for the OTP release.
    #
    # Usage:
    #   daemon              interactive chat (default)
    #   daemon setup        configure provider + API keys
    #   daemon version      print version
    #   daemon serve        headless HTTP API mode

    set -e

    # Resolve symlinks (Homebrew symlinks bin/daemon → libexec/bin/daemon)
    SCRIPT="$0"
    while [ -L "$SCRIPT" ]; do
      DIR=$(cd "$(dirname "$SCRIPT")" && pwd)
      SCRIPT=$(readlink "$SCRIPT")
      case "$SCRIPT" in /*) ;; *) SCRIPT="$DIR/$SCRIPT" ;; esac
    done
    SELF=$(cd "$(dirname "$SCRIPT")" && pwd)
    RELEASE_BIN="$SELF/daemon_release"

    case "${1:-chat}" in
      version)
        exec "$RELEASE_BIN" eval "Daemon.CLI.version()"
        ;;
      setup)
        exec "$RELEASE_BIN" eval "Daemon.CLI.setup()"
        ;;
      serve)
        exec "$RELEASE_BIN" eval "Daemon.CLI.serve()"
        ;;
      doctor)
        exec "$RELEASE_BIN" eval "Daemon.CLI.doctor()"
        ;;
      chat|*)
        exec "$RELEASE_BIN" eval "Daemon.CLI.chat()"
        ;;
    esac
    """
    |> String.trim_leading()
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CONTRIBUTING.md", "LICENSE"]
    ]
  end
end
