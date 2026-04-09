defmodule Daemon.Production.FilmProducer do
  @moduledoc """
  Orchestrator GenServer that dispatches the same film brief to multiple
  production platforms simultaneously (Flow, Sora, Kling).

  Tracks progress across all running pipelines, handles partial failures
  (one platform crashing doesn't stop the others), and broadcasts
  `{:film_producer, :all_complete, results}` when every platform finishes.

  ## Usage

      FilmProducer.produce(%{
        title: "TUNIS 626",
        character_bible: "AMIRA: Tunisian young woman...",
        preset: "City of God 2002",
        scenes: [
          %{title: "The Sound", prompt: "She walks through the medina..."},
          %{title: "The Find", prompt: "She kneels and finds the creature..."}
        ]
      }, platforms: [:flow, :sora, :kling])

      FilmProducer.status()
      #=> %{flow: %{status: :running, ...}, sora: %{status: :complete, ...}, ...}

      FilmProducer.abort()
  """
  use GenServer

  require Logger

  @poll_interval_ms 15_000

  @platform_modules %{
    flow: Daemon.Production.FilmPipeline,
    sora: Daemon.Production.SoraPipeline,
    kling: Daemon.Production.KlingPipeline
  }

  @all_platforms Map.keys(@platform_modules)

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dispatch a production brief to the given platforms (default: all available).

  Options:
    - `:platforms` — list of atoms, e.g. `[:flow, :sora, :kling]`
  """
  @spec produce(map(), keyword()) :: :ok | {:error, :already_producing} | {:error, :no_platforms}
  def produce(brief, opts \\ []) when is_map(brief) do
    GenServer.call(__MODULE__, {:produce, brief, opts})
  end

  @doc "Returns status of all tracked platforms."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Abort all running platforms."
  @spec abort() :: :ok
  def abort do
    GenServer.call(__MODULE__, :abort)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Daemon.PubSub, "osa:production")
    {:ok, initial_state()}
  end

  @impl true
  def handle_call({:produce, brief, opts}, _from, %{brief: nil} = state) do
    requested = Keyword.get(opts, :platforms, @all_platforms)

    # Filter to only platforms whose module process is alive and idle
    launchable =
      Enum.filter(requested, fn platform ->
        case Map.get(@platform_modules, platform) do
          nil ->
            Logger.warning("[FilmProducer] Unknown platform: #{platform}")
            false

          mod ->
            if process_alive?(mod) do
              case safe_status(mod) do
                %{state: :idle} ->
                  true

                %{state: current} ->
                  Logger.warning("[FilmProducer] #{platform} is #{current}, skipping")

                  false
              end
            else
              Logger.warning("[FilmProducer] #{platform} process not running, skipping")
              false
            end
        end
      end)

    if launchable == [] do
      {:reply, {:error, :no_platforms}, state}
    else
      platforms_map =
        Map.new(launchable, fn platform ->
          {platform,
           %{status: :running, started_at: DateTime.utc_now(), completed_at: nil, error: nil}}
        end)

      # Merge with idle defaults for non-launched platforms
      full_platforms =
        Map.merge(
          Map.new(@all_platforms, fn p ->
            {p, %{status: :idle, started_at: nil, completed_at: nil, error: nil}}
          end),
          platforms_map
        )

      new_state = %{
        state
        | brief: brief,
          platforms: full_platforms,
          started_at: DateTime.utc_now()
      }

      # Dispatch to each launchable platform
      Enum.each(launchable, fn platform ->
        mod = Map.fetch!(@platform_modules, platform)

        case mod.produce(brief) do
          :ok ->
            Logger.info("[FilmProducer] Dispatched to #{platform}")

          {:error, reason} ->
            Logger.error("[FilmProducer] #{platform} rejected brief: #{inspect(reason)}")
        end
      end)

      Logger.info(
        "[FilmProducer] Production started on #{length(launchable)} platform(s): #{inspect(launchable)}"
      )

      broadcast(:started, %{platforms: launchable, title: Map.get(brief, :title, "Untitled")})

      # Start the status polling timer
      timer_ref = Process.send_after(self(), :poll_status, @poll_interval_ms)
      new_state = %{new_state | timer_ref: timer_ref}

      {:reply, :ok, new_state}
    end
  end

  def handle_call({:produce, _brief, _opts}, _from, state) do
    {:reply, {:error, :already_producing}, state}
  end

  def handle_call(:status, _from, state) do
    reply =
      Map.new(state.platforms, fn {platform, info} ->
        # Enrich with live pipeline status when running
        enriched =
          if info.status == :running do
            mod = Map.get(@platform_modules, platform)

            if mod && process_alive?(mod) do
              live = safe_status(mod)
              Map.merge(info, Map.take(live, [:state, :current_scene, :total_scenes]))
            else
              info
            end
          else
            info
          end

        {platform, enriched}
      end)

    {:reply, reply, state}
  end

  def handle_call(:abort, _from, state) do
    if state.brief do
      # Abort each running platform
      Enum.each(state.platforms, fn {platform, info} ->
        if info.status == :running do
          mod = Map.get(@platform_modules, platform)

          if mod && process_alive?(mod) do
            try do
              mod.abort()
              Logger.info("[FilmProducer] Aborted #{platform}")
            rescue
              e ->
                Logger.warning(
                  "[FilmProducer] Error aborting #{platform}: #{Exception.message(e)}"
                )
            end
          end
        end
      end)

      if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
      broadcast(:aborted, %{title: Map.get(state.brief, :title, "Untitled")})
      Logger.warning("[FilmProducer] All platforms aborted")
    end

    {:reply, :ok, initial_state()}
  end

  # ── PubSub Handlers ────────────────────────────────────────────────────

  @impl true
  def handle_info({:film_pipeline, :complete, data}, state) do
    handle_platform_complete(:flow, data, state)
  end

  def handle_info({:sora_pipeline, :complete, data}, state) do
    handle_platform_complete(:sora, data, state)
  end

  def handle_info({:kling_pipeline, :complete, data}, state) do
    handle_platform_complete(:kling, data, state)
  end

  def handle_info({:film_pipeline, :failed, data}, state) do
    handle_platform_failed(:flow, data, state)
  end

  def handle_info({:sora_pipeline, :failed, data}, state) do
    handle_platform_failed(:sora, data, state)
  end

  def handle_info({:kling_pipeline, :failed, data}, state) do
    handle_platform_failed(:kling, data, state)
  end

  # Ignore other PubSub messages (scene_submitted, aborted, etc.)
  def handle_info({source, _event, _data}, state)
      when source in [:film_pipeline, :sora_pipeline, :kling_pipeline] do
    {:noreply, state}
  end

  # Shared production topic publishers may emit unrelated tuples (for example
  # ComfyUI scene runner progress). Ignore any other production event shape.
  def handle_info({_source, _event, _data}, state) do
    {:noreply, state}
  end

  # ── Status Polling ─────────────────────────────────────────────────────

  def handle_info(:poll_status, %{brief: nil} = state) do
    # No active production — don't reschedule
    {:noreply, state}
  end

  def handle_info(:poll_status, state) do
    # Build a progress summary line
    parts =
      Enum.map(state.platforms, fn {platform, info} ->
        if info.status == :running do
          mod = Map.get(@platform_modules, platform)

          if mod && process_alive?(mod) do
            live = safe_status(mod)
            scene = Map.get(live, :current_scene, "?")
            total = Map.get(live, :total_scenes, "?")
            "#{platform_label(platform)}: scene #{scene}/#{total}"
          else
            "#{platform_label(platform)}: process gone"
          end
        else
          "#{platform_label(platform)}: #{info.status}"
        end
      end)

    Logger.info("[FilmProducer] #{Enum.join(parts, ", ")}")

    # Check if any running platforms have actually completed (in case we missed PubSub)
    state = check_for_missed_completions(state)

    if all_done?(state) do
      finalize(state)
    else
      timer_ref = Process.send_after(self(), :poll_status, @poll_interval_ms)
      {:noreply, %{state | timer_ref: timer_ref}}
    end
  end

  # ── Private Helpers ────────────────────────────────────────────────────

  defp handle_platform_complete(platform, data, state) do
    Logger.info("[FilmProducer] #{platform_label(platform)} completed: #{inspect(data)}")

    state =
      update_platform(state, platform, %{
        status: :complete,
        completed_at: DateTime.utc_now()
      })

    broadcast(:platform_complete, %{platform: platform, data: data})

    if all_done?(state) do
      finalize(state)
    else
      {:noreply, state}
    end
  end

  defp handle_platform_failed(platform, data, state) do
    error = Map.get(data, :error, "unknown")
    Logger.error("[FilmProducer] #{platform_label(platform)} failed: #{error}")

    state =
      update_platform(state, platform, %{
        status: :failed,
        completed_at: DateTime.utc_now(),
        error: error
      })

    broadcast(:platform_failed, %{platform: platform, error: error})

    if all_done?(state) do
      finalize(state)
    else
      {:noreply, state}
    end
  end

  defp finalize(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    results =
      Map.new(state.platforms, fn {platform, info} ->
        {platform, Map.take(info, [:status, :started_at, :completed_at, :error])}
      end)

    succeeded = Enum.count(results, fn {_, r} -> r.status == :complete end)
    failed = Enum.count(results, fn {_, r} -> r.status == :failed end)

    Logger.info("[FilmProducer] All platforms done — #{succeeded} complete, #{failed} failed")

    broadcast(:all_complete, results)

    # Reset state but keep results accessible for one more status() call
    {:noreply, %{initial_state() | platforms: state.platforms}}
  end

  defp update_platform(state, platform, updates) do
    current = Map.get(state.platforms, platform, %{})
    updated = Map.merge(current, updates)
    %{state | platforms: Map.put(state.platforms, platform, updated)}
  end

  defp check_for_missed_completions(state) do
    Enum.reduce(state.platforms, state, fn {platform, info}, acc ->
      if info.status == :running do
        mod = Map.get(@platform_modules, platform)

        cond do
          mod == nil ->
            acc

          not process_alive?(mod) ->
            Logger.warning("[FilmProducer] #{platform} process died — marking failed")

            update_platform(acc, platform, %{
              status: :failed,
              completed_at: DateTime.utc_now(),
              error: "process_died"
            })

          true ->
            live = safe_status(mod)

            case Map.get(live, :state) do
              :complete ->
                Logger.info("[FilmProducer] #{platform} completed (detected via poll)")

                update_platform(acc, platform, %{
                  status: :complete,
                  completed_at: DateTime.utc_now()
                })

              :failed ->
                Logger.warning("[FilmProducer] #{platform} failed (detected via poll)")

                update_platform(acc, platform, %{
                  status: :failed,
                  completed_at: DateTime.utc_now(),
                  error: "pipeline_failed"
                })

              _ ->
                acc
            end
        end
      else
        acc
      end
    end)
  end

  defp all_done?(state) do
    state.platforms
    |> Enum.filter(fn {_p, info} -> info.status in [:running] end)
    |> Enum.empty?() and state.brief != nil
  end

  defp process_alive?(module) do
    case Process.whereis(module) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp safe_status(module) do
    try do
      module.status()
    rescue
      _ -> %{state: :unknown}
    catch
      :exit, _ -> %{state: :unknown}
    end
  end

  defp platform_label(:flow), do: "Flow"
  defp platform_label(:sora), do: "Sora"
  defp platform_label(:kling), do: "Kling"
  defp platform_label(other), do: to_string(other)

  defp broadcast(event, data) do
    Phoenix.PubSub.broadcast(
      Daemon.PubSub,
      "osa:production",
      {:film_producer, event, data}
    )
  rescue
    _ -> :ok
  end

  defp initial_state do
    %{
      brief: nil,
      platforms:
        Map.new(@all_platforms, fn p ->
          {p, %{status: :idle, started_at: nil, completed_at: nil, error: nil}}
        end),
      started_at: nil,
      timer_ref: nil
    }
  end
end
