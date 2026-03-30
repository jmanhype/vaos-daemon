defmodule Daemon.Production.SoraPipeline do
  @moduledoc """
  Production engine that autonomously produces films through OpenAI Sora 2.

  Uses Sora's Storyboard mode to submit scene pairs (2 scenes per generation).
  A 6-scene film becomes 3 storyboard generations (scenes 1+2, 3+4, 5+6).

  Requires an active ChatGPT Pro session in Chrome (user must be logged in
  to sora.chatgpt.com).

  ## Usage

      SoraPipeline.produce(%{
        title: "FREQUENCY",
        character_bible: "MAYA: Late 20s, dark curly hair...",
        reference_image: "/path/to/reference.jpg",
        preset: "In the Mood for Love 2000",
        scenes: [
          %{title: "Static", prompt: "Extreme close-up of Maya's face..."},
          %{title: "Motion", prompt: "Maya turns slowly toward camera..."}
        ]
      })

      SoraPipeline.status()
      #=> %{state: :rendering, current_scene: 2, total_scenes: 6, ...}
  """
  use GenServer

  require Logger

  alias Daemon.Production.BrowserPipeline

  @session_id "sora_pipeline"
  @window_name "Sora"
  @sora_url "https://sora.chatgpt.com"

  @render_wait_ms 180_000
  @post_navigate_ms 5_000
  @post_paste_ms 2_000
  @post_submit_ms 3_000
  @post_upload_ms 8_000
  @post_click_ms 3_000
  @poll_interval_ms 15_000

  # ── Sora DOM JS fragments (based on actual UI mapping March 2026) ───
  # Sora's composer has: textarea, Attach media, Storyboard, Sora 2, Create video
  # Storyboard mode adds: Scene 1 textarea, Scene 2 textarea, duration, orientation

  # Click the Storyboard button to enable multi-scene mode
  @click_storyboard_js ~S"""
  var btns=document.querySelectorAll('button');var found=false;for(var i=0;i<btns.length;i++){if(btns[i].textContent.trim()==='Storyboard'){btns[i].click();found=true;break;}}found?'storyboard_enabled':'storyboard_not_found'
  """

  # Click Attach media button
  @click_attach_media_js ~S"""
  var btns=document.querySelectorAll('button');var found=false;for(var i=0;i<btns.length;i++){if(btns[i].textContent.trim()==='Attach media'){btns[i].click();found=true;break;}}found?'attach_clicked':'attach_not_found'
  """

  # Find Create button coordinates for cliclick
  @find_create_js ~S"""
  var btns=document.querySelectorAll('button');for(var i=0;i<btns.length;i++){var t=btns[i].textContent.trim();if(t==='Create video'||t==='Create'){var r=btns[i].getBoundingClientRect();Math.round(r.x+r.width/2)+','+Math.round(r.y+r.height/2);break;}}
  """

  # Fill Scene 2 textarea — it's the second textarea with the scene placeholder
  # After Scene 1 is filled, click on Scene 2 header to reveal its textarea
  @click_scene2_js ~S"""
  var divs=document.querySelectorAll('div,button');for(var i=0;i<divs.length;i++){var t=divs[i].textContent.trim();if(t==='Scene 2'||t.indexOf('Scene 2')===0){divs[i].click();'scene2_clicked';break;}}
  """

  # Count "Your draft is ready" items on the Activity page
  @count_drafts_js ~S"""
  var text=document.body.innerText;var matches=text.match(/Your draft is ready/g);(matches?matches.length:0)+''
  """

  # Activity page URL (where draft notifications appear)
  @activity_url "https://sora.chatgpt.com/activity"

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec produce(map()) :: :ok | {:error, :already_producing}
  def produce(brief) when is_map(brief) do
    GenServer.call(__MODULE__, {:produce, brief})
  end

  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @spec abort() :: :ok
  def abort do
    GenServer.call(__MODULE__, :abort)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call({:produce, brief}, _from, %{state: :idle} = _state) do
    scenes = Map.get(brief, :scenes, [])

    # Pair scenes for storyboard mode (2 per generation)
    pairs = Enum.chunk_every(scenes, 2)

    new_state = %{
      state: :acquiring,
      title: Map.get(brief, :title, "Untitled"),
      character_bible: Map.get(brief, :character_bible, ""),
      reference_image: Map.get(brief, :reference_image, nil),
      preset: Map.get(brief, :preset, ""),
      duration: Map.get(brief, :duration, "10s"),
      scenes: scenes,
      scene_pairs: pairs,
      current_pair: 0,
      current_scene: 0,
      total_scenes: length(scenes),
      total_pairs: length(pairs),
      video_count_before: 0,
      errors: [],
      timer_ref: nil,
      started_at: DateTime.utc_now()
    }

    flush_render_messages()
    {:reply, :ok, new_state, {:continue, :ensure_window}}
  end

  def handle_call({:produce, _brief}, _from, state) do
    {:reply, {:error, :already_producing}, state}
  end

  def handle_call(:status, _from, state) do
    reply =
      Map.take(state, [
        :state,
        :title,
        :current_scene,
        :total_scenes,
        :errors,
        :started_at
      ])

    {:reply, reply, state}
  end

  def handle_call(:abort, _from, state) do
    if state.state != :idle do
      if state[:timer_ref], do: Process.cancel_timer(state[:timer_ref])
      broadcast(:aborted, state)
      Logger.warning("[SoraPipeline] Production aborted: #{state.title}")
    end

    {:reply, :ok, initial_state()}
  end

  # ── Pipeline Steps ─────────────────────────────────────────────────

  @impl true
  def handle_continue(:ensure_window, state) do
    Logger.info("[SoraPipeline] Ensuring Sora window exists for #{state.title}")
    BrowserPipeline.ensure_window(@window_name, @sora_url)
    Process.sleep(@post_navigate_ms)
    {:noreply, %{state | state: :navigating}, {:continue, :navigate_to_sora}}
  end

  def handle_continue(:navigate_to_sora, state) do
    BrowserPipeline.navigate(@window_name, @sora_url)
    Process.sleep(@post_navigate_ms)

    url = BrowserPipeline.get_url(@window_name)
    Logger.info("[SoraPipeline] Navigated to Sora (URL: #{url})")

    {:noreply, state, {:continue, :submit_pair}}
  end

  def handle_continue(:submit_pair, state) do
    pair_index = state.current_pair
    pair = Enum.at(state.scene_pairs, pair_index)

    if pair == nil do
      {:noreply, state, {:continue, :complete}}
    else
      scene1 = Enum.at(pair, 0)
      scene2 = Enum.at(pair, 1)
      pair_num = pair_index + 1
      scene_num_start = pair_index * 2 + 1

      Logger.info(
        "[SoraPipeline] Submitting pair #{pair_num}/#{state.total_pairs}: " <>
          "scenes #{scene_num_start}-#{scene_num_start + length(pair) - 1}"
      )

      # Navigate to sora home (fresh composer)
      BrowserPipeline.navigate(@window_name, @sora_url)
      Process.sleep(@post_navigate_ms)

      # Upload reference image on first pair only
      if pair_index == 0 && state.reference_image && File.exists?(state.reference_image) do
        upload_reference(state)
      end

      if scene2 do
        # Two scenes — use Storyboard mode
        submit_storyboard_pair(state, scene1, scene2, pair_num)
      else
        # Single scene (odd number) — submit as regular generation
        submit_single_scene(state, scene1, pair_num)
      end

      # Track what scene we're on
      scenes_done = scene_num_start + length(pair) - 1

      broadcast(:scene_submitted, %{
        pair: pair_num,
        scenes: "#{scene_num_start}-#{scenes_done}"
      })

      # Check Activity page for baseline "draft is ready" count
      Process.sleep(2_000)
      BrowserPipeline.navigate(@window_name, @activity_url <> "?t=#{System.system_time(:second)}")
      Process.sleep(4_000)
      count_before = get_video_count()
      BrowserPipeline.navigate(@window_name, @sora_url)
      Process.sleep(1_000)
      Logger.info("[SoraPipeline] Activity draft count before render: #{count_before}")

      new_state = %{
        state
        | state: :rendering,
          current_pair: pair_index,
          current_scene: scenes_done,
          video_count_before: count_before
      }

      new_state = schedule_render_poll(new_state)
      {:noreply, new_state}
    end
  end

  def handle_continue(:post_render, state) do
    Logger.info(
      "[SoraPipeline] Render complete for pair #{state.current_pair + 1} " <>
        "(scenes up to #{state.current_scene})"
    )

    next_pair = state.current_pair + 1

    if next_pair < state.total_pairs do
      {:noreply, %{state | current_pair: next_pair}, {:continue, :submit_pair}}
    else
      {:noreply, state, {:continue, :complete}}
    end
  end

  def handle_continue(:complete, state) do
    final_state = %{state | state: :complete}

    Logger.info(
      "[SoraPipeline] Production complete: #{state.title} (#{state.total_scenes} scenes in #{state.total_pairs} pairs)"
    )

    broadcast(:complete, %{title: state.title})
    {:noreply, final_state}
  end

  # ── Message Handlers ───────────────────────────────────────────────

  @impl true
  def handle_info(:poll_render, %{state: :rendering} = state) do
    # Navigate to Activity page to count "draft is ready" notifications
    BrowserPipeline.navigate(@window_name, @activity_url <> "?t=#{System.system_time(:second)}")
    Process.sleep(4_000)
    current_count = get_video_count()
    elapsed = elapsed_ms(state)

    Logger.debug(
      "[SoraPipeline] Polling activity: #{current_count} videos (was #{state.video_count_before}), elapsed=#{div(elapsed, 1000)}s"
    )

    # Navigate back to home so we're ready for next submission
    BrowserPipeline.navigate(@window_name, @sora_url)
    Process.sleep(1_000)

    cond do
      current_count > state.video_count_before ->
        Logger.info(
          "[SoraPipeline] New draft ready on Activity! (#{current_count} > #{state.video_count_before})"
        )
        {:noreply, state, {:continue, :post_render}}

      elapsed >= @render_wait_ms ->
        Logger.warning("[SoraPipeline] Render timeout after #{div(elapsed, 1000)}s — continuing")
        {:noreply, state, {:continue, :post_render}}

      true ->
        new_state = schedule_render_poll(state)
        {:noreply, new_state}
    end
  end

  def handle_info(:poll_render, state) do
    {:noreply, state}
  end

  # ── Private: Submission Helpers ────────────────────────────────────

  defp submit_storyboard_pair(state, scene1, scene2, pair_num) do
    # Step 1: Enable Storyboard mode
    sb_result = BrowserPipeline.execute_js(@window_name, @click_storyboard_js)
    Logger.info("[SoraPipeline] Storyboard mode: #{sb_result}")
    Process.sleep(2_000)

    # Step 2: Fill main prompt with character bible + preset
    main_prompt = build_main_prompt(state)

    if main_prompt != "" do
      fill_main_prompt(main_prompt)
      Process.sleep(1_000)
    end

    # Step 3: Fill Scene 1 prompt
    scene1_prompt = scene1.prompt
    fill_scene1(scene1_prompt)
    Logger.info("[SoraPipeline] Scene 1 filled: #{scene1.title}")
    Process.sleep(1_000)

    # Step 4: Click Scene 2 to reveal its textarea, then fill it
    BrowserPipeline.execute_js(@window_name, @click_scene2_js)
    Process.sleep(1_000)

    scene2_prompt = scene2.prompt
    fill_scene2(scene2_prompt)
    Logger.info("[SoraPipeline] Scene 2 filled: #{scene2.title}")
    Process.sleep(1_000)

    # Step 5: Click Create via cliclick (JS event dispatch doesn't work on Sora)
    create_result = click_create_button()
    Logger.info("[SoraPipeline] Pair #{pair_num} submitted: #{create_result}")
    Process.sleep(@post_submit_ms)
  end

  defp submit_single_scene(state, scene, pair_num) do
    # Single scene — no storyboard, just use the main prompt textarea
    prompt = build_prompt(state, scene)

    # Focus and fill the main textarea
    fill_main_prompt(prompt)
    Logger.info("[SoraPipeline] Single scene filled: #{scene.title}")
    Process.sleep(@post_paste_ms)

    # Click Create via cliclick
    create_result = click_create_button()
    Logger.info("[SoraPipeline] Single scene #{pair_num} submitted: #{create_result}")
    Process.sleep(@post_submit_ms)
  end

  defp upload_reference(state) do
    Logger.info("[SoraPipeline] Uploading reference image: #{state.reference_image}")

    # Click Attach media
    attach_result = BrowserPipeline.execute_js(@window_name, @click_attach_media_js)
    Logger.info("[SoraPipeline] Attach media click: #{attach_result}")
    Process.sleep(2_000)

    # Inject file via DataTransfer
    upload_result = BrowserPipeline.upload_file(@window_name, state.reference_image)
    Logger.info("[SoraPipeline] File upload result: #{upload_result}")
    Process.sleep(@post_upload_ms)
  end

  defp fill_main_prompt(text) do
    # Focus the main "Describe your video..." textarea, then paste
    focus_js = ~S|var tas=document.querySelectorAll('textarea');for(var i=0;i<tas.length;i++){if(tas[i].placeholder==='Describe your video...'){tas[i].focus();tas[i].click();'focused';break;}}|
    BrowserPipeline.execute_js(@window_name, focus_js)
    Process.sleep(500)
    paste_text(@window_name, text)
  end

  defp fill_scene1(text) do
    # Focus the "Describe this scene…" textarea (first one), then paste
    focus_js = ~S|var tas=document.querySelectorAll('textarea');for(var i=0;i<tas.length;i++){if(tas[i].placeholder.indexOf('Describe this scene')>-1){tas[i].focus();tas[i].click();'focused';break;}}|
    BrowserPipeline.execute_js(@window_name, focus_js)
    Process.sleep(500)
    paste_text(@window_name, text)
  end

  defp fill_scene2(text) do
    # Focus the second scene textarea, then paste
    focus_js = ~S|var tas=document.querySelectorAll('textarea');var found=[];for(var i=0;i<tas.length;i++){if(tas[i].placeholder.indexOf('Describe this scene')>-1){found.push(tas[i]);}}if(found.length>=2){found[1].focus();found[1].click();'focused_2nd';}else if(found.length===1){found[0].focus();found[0].click();'focused_1st_reuse';}else{'no_scene_textarea'}|
    BrowserPipeline.execute_js(@window_name, focus_js)
    Process.sleep(500)
    paste_text(@window_name, text)
  end

  # Click the Create button via cliclick (physical click, not JS event dispatch)
  defp click_create_button do
    result = BrowserPipeline.execute_js(@window_name, @find_create_js)

    case String.split(String.trim(result), ",") do
      [x_str, y_str] ->
        x = String.to_integer(String.trim(x_str))
        y = String.to_integer(String.trim(y_str))
        # Add Chrome's title bar offset (~28px on macOS)
        screen_y = y + 28
        Logger.info("[SoraPipeline] Clicking Create at #{x},#{screen_y}")
        BrowserPipeline.focus_and_click(@window_name, x, screen_y)
        "submitted"

      _ ->
        Logger.warning("[SoraPipeline] Could not find Create button: #{result}")
        "no_create_button"
    end
  end

  # Paste text using pbcopy + Cmd+V (the only method that works with React textareas)
  defp paste_text(window_name, text) do
    # Copy text to clipboard
    port = Port.open({:spawn, "pbcopy"}, [:binary])
    Port.command(port, text)
    Port.close(port)
    Process.sleep(300)

    # Bring window to front and Cmd+V
    BrowserPipeline.osascript([
      ~s(tell application "Google Chrome"),
      ~s(  set targetWindow to first window whose given name is "#{window_name}"),
      ~s(  set index of targetWindow to 1),
      ~s(end tell),
      ~s(delay 0.3),
      ~s(tell application "System Events"),
      ~s(  keystroke "v" using command down),
      ~s(end tell)
    ])
    Process.sleep(500)
  end

  # ── Private: Prompt Building ───────────────────────────────────────

  defp build_main_prompt(state) do
    parts = []
    parts = if state.preset != "", do: parts ++ ["[#{state.preset}]"], else: parts
    parts = if state.character_bible != "", do: parts ++ [state.character_bible], else: parts
    Enum.join(parts, "\n\n")
  end

  defp build_prompt(state, scene) do
    parts = []
    parts = if state.preset != "", do: parts ++ ["[#{state.preset}]"], else: parts
    parts = if state.character_bible != "", do: parts ++ [state.character_bible], else: parts
    parts = parts ++ [scene.prompt]
    Enum.join(parts, "\n\n")
  end

  # ── Private: Polling & Timing ──────────────────────────────────────

  defp get_video_count do
    result = BrowserPipeline.execute_js(@window_name, @count_drafts_js)

    case Integer.parse(String.trim(result)) do
      {n, _} -> n
      :error -> 0
    end
  end


  defp schedule_render_poll(state) do
    if state[:timer_ref], do: Process.cancel_timer(state[:timer_ref])
    ref = Process.send_after(self(), :poll_render, @poll_interval_ms)
    %{state | timer_ref: ref}
  end

  defp elapsed_ms(state) do
    case state.started_at do
      nil -> 0
      started -> DateTime.diff(DateTime.utc_now(), started, :millisecond)
    end
  end

  # ── Private: State & PubSub ────────────────────────────────────────

  defp broadcast(event, data \\ %{}) do
    Phoenix.PubSub.broadcast(
      Daemon.PubSub,
      "osa:production",
      {:sora_pipeline, event, data}
    )
  rescue
    _ -> :ok
  end

  defp flush_render_messages do
    receive do
      :poll_render -> flush_render_messages()
    after
      0 -> :ok
    end
  end

  defp initial_state do
    %{
      state: :idle,
      title: nil,
      character_bible: nil,
      reference_image: nil,
      preset: nil,
      duration: "10s",
      scenes: [],
      scene_pairs: [],
      current_pair: 0,
      current_scene: 0,
      total_scenes: 0,
      total_pairs: 0,
      video_count_before: 0,
      errors: [],
      timer_ref: nil,
      started_at: nil
    }
  end
end
