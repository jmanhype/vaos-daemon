defmodule Daemon.Production.KlingPipeline do
  @moduledoc """
  Production engine that autonomously produces films through Kling AI (app.klingai.com).

  Receives the same production brief as FilmPipeline and SoraPipeline and drives
  the full pipeline: window setup, Image-to-Video for scene 1 (with reference
  image upload), render polling, and Extend chains for scenes 2-N.

  Requires an active Kling AI session in Chrome (user must be logged in).

  ## Kling-specific features

  - Image-to-Video mode for scene 1 with reference image upload
  - Extend mode for subsequent scenes (appends 5s with new prompt)
  - Settings: aspect ratio, duration (5s/10s/15s), quality, camera movement, motion intensity
  - Elements tab for character consistency (multi-angle reference)
  - Native audio generation toggle
  - Bind Subject toggle for character consistency

  ## Usage

      KlingPipeline.produce(%{
        title: "FREQUENCY",
        character_bible: "MAYA: Late 20s, dark curly hair...",
        reference_image: "/path/to/reference.jpg",
        preset: "In the Mood for Love 2000",
        aspect_ratio: "16:9",
        duration: "10s",
        quality: "Pro",
        motion_intensity: 3,
        scenes: [
          %{title: "Static", prompt: "Extreme close-up of Maya's face..."},
          %{title: "Motion", prompt: "Maya turns slowly toward camera..."}
        ]
      })

      KlingPipeline.status()
      #=> %{state: :rendering, current_scene: 2, total_scenes: 4, ...}
  """
  use GenServer

  require Logger

  alias Daemon.Production.BrowserPipeline

  @window_name "Kling"
  @kling_url "https://app.klingai.com/global/"

  @render_wait_ms 120_000
  @post_navigate_ms 5_000
  @post_paste_ms 1_500
  @post_submit_ms 3_000
  @post_upload_ms 8_000
  @post_click_ms 3_000
  @poll_interval_ms 5_000

  # ── Kling DOM selector JS fragments ──────────────────────────────────
  # These target Kling AI's React SPA DOM patterns. Selectors may need
  # tuning as the UI evolves.

  # Click the "AI Video" tab in the sidebar
  @click_ai_video_tab_js ~S"""
  var tabs=document.querySelectorAll('span,div,a,li');var found=false;for(var i=0;i<tabs.length;i++){var text=tabs[i].textContent.trim().toLowerCase();if(text==='ai video'){tabs[i].click();found=true;break;}}found?'ai_video_clicked':'ai_video_not_found'
  """

  # Click Image-to-Video mode tab
  @click_image_to_video_js ~S"""
  var tabs=document.querySelectorAll('div[role="tab"],button,span,a');var found=false;for(var i=0;i<tabs.length;i++){var text=tabs[i].textContent.trim().toLowerCase();if(text.indexOf('image to video')>-1||text.indexOf('image-to-video')>-1||text.indexOf('img2video')>-1){tabs[i].click();found=true;break;}}found?'image_to_video_selected':'image_to_video_not_found'
  """

  # Click Text-to-Video mode tab
  @click_text_to_video_js ~S"""
  var tabs=document.querySelectorAll('div[role="tab"],button,span,a');var found=false;for(var i=0;i<tabs.length;i++){var text=tabs[i].textContent.trim().toLowerCase();if(text.indexOf('text to video')>-1||text.indexOf('text-to-video')>-1||text.indexOf('txt2video')>-1){tabs[i].click();found=true;break;}}found?'text_to_video_selected':'text_to_video_not_found'
  """

  # Find the prompt textarea
  @prompt_selector_js ~S"""
  document.querySelector('textarea[placeholder*="prompt"]') || document.querySelector('textarea[placeholder*="Prompt"]') || document.querySelector('textarea[placeholder*="describe"]') || document.querySelector('textarea[placeholder*="Describe"]') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]') || document.querySelector('div[role="textbox"]')
  """

  # Click the Generate button
  @generate_js ~S"""
  var btns=document.querySelectorAll('button');var found=false;for(var i=0;i<btns.length;i++){var text=btns[i].textContent.trim().toLowerCase();if(text.indexOf('generate')>-1||text.indexOf('create')>-1){var r=btns[i].getBoundingClientRect();if(r.width>0&&r.height>0){['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){btns[i].dispatchEvent(new PointerEvent(t,{bubbles:true,cancelable:true,clientX:r.x+r.width/2,clientY:r.y+r.height/2,pointerId:1}))});found=true;break;}}}found?'generate_clicked':'generate_not_found'
  """

  # Count video/media tiles in the creatives gallery
  @count_videos_js ~S"""
  var vids=document.querySelectorAll('video');var imgs=document.querySelectorAll('img[src*="blob"],img[src*="kling"],img[alt*="Generated"],img[alt*="generated"],.video-card,.creation-item,.creative-item');(vids.length+imgs.length)+''
  """

  # Click the first video tile in My Creatives
  @click_first_video_js ~S"""
  var vids=document.querySelectorAll('video');if(vids.length>0){var el=vids[0].closest('a')||vids[0].closest('[role="button"]')||vids[0].closest('.video-card')||vids[0].parentElement;if(el){el.click();'clicked_video'}else{vids[0].click();'clicked_video_direct'}}else{var cards=document.querySelectorAll('.video-card,.creation-item,.creative-item');if(cards.length>0){cards[0].click();'clicked_card'}else{'no_media'}}
  """

  # Click the Extend button on a completed video
  @extend_button_js ~S"""
  var btns=document.querySelectorAll('button,a,span');var found=false;for(var i=0;i<btns.length;i++){var text=btns[i].textContent.trim().toLowerCase();if(text.indexOf('extend')>-1||text.indexOf('continue')>-1){var r=btns[i].getBoundingClientRect();if(r.width>0&&r.height>0){['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){btns[i].dispatchEvent(new PointerEvent(t,{bubbles:true,cancelable:true,clientX:r.x+r.width/2,clientY:r.y+r.height/2,pointerId:1}))});found=true;break;}}}found?'extend_clicked':'extend_not_found'
  """

  # Set aspect ratio (16:9, 9:16, 1:1)
  @aspect_ratio_js_template ~S"""
  var opts=document.querySelectorAll('div[role="option"],button,span,li');var found=false;for(var i=0;i<opts.length;i++){var text=opts[i].textContent.trim();if(text==='RATIO_VAL'){opts[i].click();found=true;break;}}found?'ratio_set':'ratio_not_found'
  """

  # Set duration (5s, 10s, 15s)
  @duration_js_template ~S"""
  var opts=document.querySelectorAll('div[role="option"],button,span,li');var found=false;for(var i=0;i<opts.length;i++){var text=opts[i].textContent.trim();if(text==='DURATION_VAL'||text==='DURATION_VALs'){opts[i].click();found=true;break;}}found?'duration_set':'duration_not_found'
  """

  # Set quality (Standard, Pro, Master)
  @quality_js_template ~S"""
  var opts=document.querySelectorAll('div[role="option"],button,span,li');var found=false;for(var i=0;i<opts.length;i++){var text=opts[i].textContent.trim().toLowerCase();if(text==='QUALITY_VAL'){opts[i].click();found=true;break;}}found?'quality_set':'quality_not_found'
  """

  # Set motion intensity (slider 1-5)
  @motion_intensity_js_template ~S"""
  var sliders=document.querySelectorAll('input[type="range"]');var found=false;for(var i=0;i<sliders.length;i++){var label=(sliders[i].getAttribute('aria-label')||'').toLowerCase();var parent=sliders[i].closest('[class*="motion"]')||sliders[i].closest('[class*="intensity"]');if(label.indexOf('motion')>-1||label.indexOf('intensity')>-1||parent){var nativeInputValueSetter=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;nativeInputValueSetter.call(sliders[i],'INTENSITY_VAL');sliders[i].dispatchEvent(new Event('input',{bubbles:true}));sliders[i].dispatchEvent(new Event('change',{bubbles:true}));found=true;break;}}found?'intensity_set':'intensity_not_found'
  """

  # Click image upload area in Image-to-Video mode
  @image_upload_area_js ~S"""
  var areas=document.querySelectorAll('[class*="upload"],div[role="button"],button');var found=false;for(var i=0;i<areas.length;i++){var text=areas[i].textContent.trim().toLowerCase();var ariaLabel=(areas[i].getAttribute('aria-label')||'').toLowerCase();if(text.indexOf('upload')>-1||text.indexOf('drag')>-1||text.indexOf('click to upload')>-1||ariaLabel.indexOf('upload')>-1){areas[i].click();found=true;break;}}found?'upload_area_clicked':'upload_area_not_found'
  """

  # Check if a video is still rendering (look for progress indicators)
  @check_rendering_js ~S"""
  var indicators=document.querySelectorAll('[class*="progress"],[class*="loading"],[class*="generating"],[class*="pending"],.ant-spin,.loading-spinner');var text=document.body.innerText.toLowerCase();var isRendering=(indicators.length>0)||(text.indexOf('generating')>-1&&text.indexOf('in queue')>-1)||(text.indexOf('processing')>-1);isRendering?'rendering':'done'
  """

  # Navigate to My Creatives gallery
  @navigate_creatives_js ~S"""
  var links=document.querySelectorAll('a,span,div,button');var found=false;for(var i=0;i<links.length;i++){var text=links[i].textContent.trim().toLowerCase();if(text.indexOf('my creative')>-1||text.indexOf('my video')>-1||text.indexOf('history')>-1){links[i].click();found=true;break;}}found?'creatives_clicked':'creatives_not_found'
  """

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a production run. Expects a map with:
    - `:title` — film title
    - `:character_bible` — full character description text
    - `:reference_image` — optional path to a reference image (JPEG/PNG, min 1024x1024)
    - `:preset` — cinematic preset name
    - `:scenes` — list of `%{title: String.t(), prompt: String.t()}`
    - `:aspect_ratio` — optional, one of "16:9", "9:16", "1:1" (default "16:9")
    - `:duration` — optional, one of "5s", "10s", "15s" (default "5s")
    - `:quality` — optional, one of "standard", "pro", "master" (default "pro")
    - `:motion_intensity` — optional, integer 1-5 (default 3)
  """
  @spec produce(map()) :: :ok | {:error, :already_producing}
  def produce(brief) when is_map(brief) do
    GenServer.call(__MODULE__, {:produce, brief})
  end

  @doc "Returns current pipeline status."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Abort the current production run."
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

    new_state = %{
      state: :acquiring,
      title: Map.get(brief, :title, "Untitled"),
      character_bible: Map.get(brief, :character_bible, ""),
      reference_image: Map.get(brief, :reference_image, nil),
      preset: Map.get(brief, :preset, ""),
      aspect_ratio: Map.get(brief, :aspect_ratio, "16:9"),
      duration: Map.get(brief, :duration, "5s"),
      quality: Map.get(brief, :quality, "pro"),
      motion_intensity: Map.get(brief, :motion_intensity, 3),
      scenes: scenes,
      current_scene: 0,
      total_scenes: length(scenes),
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
      Logger.warning("[KlingPipeline] Production aborted: #{state.title}")
    end

    {:reply, :ok, initial_state()}
  end

  # ── Pipeline Steps (handle_continue) ────────────────────────────────

  @impl true
  def handle_continue(:ensure_window, state) do
    Logger.info("[KlingPipeline] Ensuring Kling window exists for #{state.title}")
    BrowserPipeline.ensure_window(@window_name, @kling_url)
    Process.sleep(@post_navigate_ms)
    {:noreply, %{state | state: :navigating}, {:continue, :navigate_to_kling}}
  end

  def handle_continue(:navigate_to_kling, state) do
    # Navigate to Kling AI main page
    BrowserPipeline.navigate(@window_name, @kling_url)
    Process.sleep(@post_navigate_ms)

    url = BrowserPipeline.get_url(@window_name)
    Logger.info("[KlingPipeline] Navigated to Kling AI (URL: #{url})")

    # Click the AI Video tab in the sidebar
    tab_result = BrowserPipeline.execute_js(@window_name, @click_ai_video_tab_js)
    Logger.info("[KlingPipeline] AI Video tab click: #{tab_result}")
    Process.sleep(@post_click_ms)

    # Choose mode based on whether we have a reference image
    if state.reference_image && File.exists?(state.reference_image) do
      mode_result = BrowserPipeline.execute_js(@window_name, @click_image_to_video_js)
      Logger.info("[KlingPipeline] Image-to-Video mode: #{mode_result}")
      Process.sleep(@post_click_ms)
      {:noreply, %{state | state: :uploading_reference}, {:continue, :upload_reference}}
    else
      mode_result = BrowserPipeline.execute_js(@window_name, @click_text_to_video_js)
      Logger.info("[KlingPipeline] Text-to-Video mode: #{mode_result}")
      Process.sleep(@post_click_ms)
      {:noreply, %{state | state: :submitting_first}, {:continue, :configure_settings}}
    end
  end

  def handle_continue(:upload_reference, state) do
    Logger.info("[KlingPipeline] Uploading reference image: #{state.reference_image}")

    # Click the upload area to trigger file input
    area_result = BrowserPipeline.execute_js(@window_name, @image_upload_area_js)
    Logger.info("[KlingPipeline] Upload area click: #{area_result}")
    Process.sleep(2_000)

    # Inject the file via DataTransfer
    upload_result = BrowserPipeline.upload_file(@window_name, state.reference_image)
    Logger.info("[KlingPipeline] File injection result: #{upload_result}")
    Process.sleep(@post_upload_ms)

    {:noreply, %{state | state: :submitting_first}, {:continue, :configure_settings}}
  end

  def handle_continue(:configure_settings, state) do
    Logger.info("[KlingPipeline] Configuring generation settings")

    # Set aspect ratio
    ar_js = String.replace(@aspect_ratio_js_template, "RATIO_VAL", state.aspect_ratio)
    ar_result = BrowserPipeline.execute_js(@window_name, ar_js)
    Logger.debug("[KlingPipeline] Set aspect ratio #{state.aspect_ratio}: #{ar_result}")
    Process.sleep(500)

    # Set duration
    dur_val = String.replace(state.duration, ~r/[^0-9s]/, "")
    dur_js = String.replace(@duration_js_template, "DURATION_VAL", dur_val)
    dur_result = BrowserPipeline.execute_js(@window_name, dur_js)
    Logger.debug("[KlingPipeline] Set duration #{dur_val}: #{dur_result}")
    Process.sleep(500)

    # Set quality
    qual_js = String.replace(@quality_js_template, "QUALITY_VAL", state.quality)
    qual_result = BrowserPipeline.execute_js(@window_name, qual_js)
    Logger.debug("[KlingPipeline] Set quality #{state.quality}: #{qual_result}")
    Process.sleep(500)

    # Set motion intensity
    intensity_js =
      String.replace(
        @motion_intensity_js_template,
        "INTENSITY_VAL",
        to_string(state.motion_intensity)
      )

    intensity_result = BrowserPipeline.execute_js(@window_name, intensity_js)
    Logger.debug("[KlingPipeline] Set motion intensity #{state.motion_intensity}: #{intensity_result}")
    Process.sleep(500)

    {:noreply, state, {:continue, :submit_first_scene}}
  end

  def handle_continue(:submit_first_scene, state) do
    scene = Enum.at(state.scenes, 0)
    prompt = build_prompt(state, scene)

    Logger.info("[KlingPipeline] Submitting scene 1/#{state.total_scenes}: #{scene.title}")

    # Snapshot current video count before submitting
    count_before = get_video_count()
    Logger.info("[KlingPipeline] Videos before submit: #{count_before}")

    # Paste prompt into the textarea
    BrowserPipeline.focus_and_paste(@window_name, @prompt_selector_js, prompt)
    Process.sleep(@post_paste_ms)

    # Click Generate button
    gen_result = BrowserPipeline.execute_js(@window_name, @generate_js)
    Logger.info("[KlingPipeline] Generate result: #{gen_result}")

    # Fallback: try Enter key if no button found
    if gen_result == "generate_not_found" do
      BrowserPipeline.osascript([
        ~s(tell application "Google Chrome"),
        ~s(  set targetWindow to first window whose given name is "#{@window_name}"),
        ~s(  set index of targetWindow to 1),
        ~s(end tell),
        ~s(delay 0.3),
        ~s(tell application "System Events"),
        ~s(  key code 36),
        ~s(end tell)
      ])
    end

    Process.sleep(@post_submit_ms)

    broadcast(:scene_submitted, %{scene: 1, title: scene.title})
    Logger.info("[KlingPipeline] Scene 1 submitted (awaiting render)")

    new_state = %{state | state: :rendering, current_scene: 1, video_count_before: count_before}
    new_state = schedule_render_poll(new_state)
    {:noreply, new_state}
  end

  def handle_continue(:post_render, state) do
    Logger.info("[KlingPipeline] Render complete for scene #{state.current_scene}")

    if state.current_scene < state.total_scenes do
      {:noreply, %{state | state: :extending}, {:continue, :extend_next_scene}}
    else
      {:noreply, state, {:continue, :complete}}
    end
  end

  def handle_continue(:extend_next_scene, state) do
    next_index = state.current_scene
    scene = Enum.at(state.scenes, next_index)

    if scene == nil do
      {:noreply, state, {:continue, :complete}}
    else
      scene_num = next_index + 1

      Logger.info(
        "[KlingPipeline] Extending scene #{scene_num}/#{state.total_scenes}: #{scene.title}"
      )

      # Click the most recent video tile to enter detail view
      click_result = BrowserPipeline.execute_js(@window_name, @click_first_video_js)
      Logger.info("[KlingPipeline] Click video result: #{click_result}")
      Process.sleep(@post_click_ms)

      # Click the Extend button to append 5 seconds
      extend_result = BrowserPipeline.execute_js(@window_name, @extend_button_js)
      Logger.info("[KlingPipeline] Extend button result: #{extend_result}")

      if extend_result == "extend_not_found" do
        # Fallback: navigate to creatives, click the video, try again
        Logger.info("[KlingPipeline] Extend not found — trying via My Creatives")
        BrowserPipeline.execute_js(@window_name, @navigate_creatives_js)
        Process.sleep(@post_click_ms)
        BrowserPipeline.execute_js(@window_name, @click_first_video_js)
        Process.sleep(@post_click_ms)
        retry_result = BrowserPipeline.execute_js(@window_name, @extend_button_js)
        Logger.info("[KlingPipeline] Extend retry result: #{retry_result}")

        if retry_result == "extend_not_found" do
          # Final fallback: generate as independent scene
          Logger.warning("[KlingPipeline] No extend button — generating scene #{scene_num} independently")
          generate_independent_scene(state, scene, scene_num)
        end
      end

      # If extend was found, paste the new prompt for the extension
      if extend_result != "extend_not_found" do
        Process.sleep(@post_click_ms)
        prompt = build_prompt(state, scene)
        BrowserPipeline.focus_and_paste(@window_name, @prompt_selector_js, prompt)
        Process.sleep(@post_paste_ms)

        gen_result = BrowserPipeline.execute_js(@window_name, @generate_js)
        Logger.info("[KlingPipeline] Extend generate: #{gen_result}")
        Process.sleep(@post_submit_ms)
      end

      broadcast(:scene_submitted, %{scene: scene_num, title: scene.title})

      count_before = get_video_count()
      new_state = %{state | state: :rendering, current_scene: scene_num, video_count_before: count_before}
      new_state = schedule_render_poll(new_state)
      {:noreply, new_state}
    end
  end

  def handle_continue(:complete, state) do
    final_state = %{state | state: :complete}

    Logger.info(
      "[KlingPipeline] Production complete: #{state.title} (#{state.total_scenes} scenes)"
    )

    broadcast(:complete, %{title: state.title})
    {:noreply, final_state}
  end

  # ── Message Handlers ────────────────────────────────────────────────

  @impl true
  def handle_info(:poll_render, %{state: :rendering} = state) do
    current_count = get_video_count()

    Logger.debug(
      "[KlingPipeline] Polling render: #{current_count} videos (was #{state.video_count_before})"
    )

    # Also check if Kling's UI shows rendering indicators
    render_status = BrowserPipeline.execute_js(@window_name, @check_rendering_js)

    cond do
      current_count > state.video_count_before ->
        Logger.info(
          "[KlingPipeline] New video detected (#{current_count} > #{state.video_count_before})"
        )

        {:noreply, state, {:continue, :post_render}}

      render_status == "done" and elapsed_ms(state) > 30_000 ->
        # UI says done but video count didn't increase — check passed enough time
        Logger.info("[KlingPipeline] Render indicators cleared — treating as complete")
        {:noreply, state, {:continue, :post_render}}

      elapsed_ms(state) >= @render_wait_ms ->
        Logger.warning(
          "[KlingPipeline] Render timeout for scene #{state.current_scene} — continuing anyway"
        )

        {:noreply, state, {:continue, :post_render}}

      true ->
        # Keep polling
        new_state = schedule_render_poll(state)
        {:noreply, new_state}
    end
  end

  def handle_info(:poll_render, state) do
    # Stale poll — ignore
    {:noreply, state}
  end

  def handle_info(:render_complete, state) do
    # Legacy compatibility
    {:noreply, state}
  end

  # ── Private Helpers ─────────────────────────────────────────────────

  defp generate_independent_scene(state, scene, scene_num) do
    # Navigate back to Kling main page and start a fresh generation
    BrowserPipeline.navigate(@window_name, @kling_url)
    Process.sleep(@post_navigate_ms)

    # Click AI Video tab
    BrowserPipeline.execute_js(@window_name, @click_ai_video_tab_js)
    Process.sleep(@post_click_ms)

    # Re-upload reference image if available
    if state.reference_image && File.exists?(state.reference_image) do
      BrowserPipeline.execute_js(@window_name, @click_image_to_video_js)
      Process.sleep(@post_click_ms)

      area_result = BrowserPipeline.execute_js(@window_name, @image_upload_area_js)
      Logger.info("[KlingPipeline] Re-upload for scene #{scene_num}: #{area_result}")
      Process.sleep(2_000)
      BrowserPipeline.upload_file(@window_name, state.reference_image)
      Process.sleep(@post_upload_ms)
    else
      BrowserPipeline.execute_js(@window_name, @click_text_to_video_js)
      Process.sleep(@post_click_ms)
    end

    # Paste and submit
    prompt = build_prompt(state, scene)
    BrowserPipeline.focus_and_paste(@window_name, @prompt_selector_js, prompt)
    Process.sleep(@post_paste_ms)

    gen_result = BrowserPipeline.execute_js(@window_name, @generate_js)
    Logger.info("[KlingPipeline] Independent scene #{scene_num} generate: #{gen_result}")
    Process.sleep(@post_submit_ms)
  end

  defp get_video_count do
    result = BrowserPipeline.execute_js(@window_name, @count_videos_js)

    case Integer.parse(String.trim(result)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp build_prompt(state, scene) do
    parts = []
    parts = if state.preset != "", do: parts ++ ["[#{state.preset}]"], else: parts
    parts = if state.character_bible != "", do: parts ++ [state.character_bible], else: parts
    parts = parts ++ [scene.prompt]

    prompt = Enum.join(parts, "\n\n")

    # Kling has a 2500 char limit
    if String.length(prompt) > 2500 do
      Logger.warning("[KlingPipeline] Prompt truncated from #{String.length(prompt)} to 2500 chars")
      String.slice(prompt, 0, 2500)
    else
      prompt
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

  defp fail(state, error) do
    new_state = %{state | state: :failed, errors: [error | state.errors]}
    broadcast(:failed, %{title: state.title, error: error})
    Logger.error("[KlingPipeline] Production failed: #{error}")
    new_state
  end

  defp broadcast(event, data \\ %{}) do
    Phoenix.PubSub.broadcast(
      Daemon.PubSub,
      "osa:production",
      {:kling_pipeline, event, data}
    )
  rescue
    _ -> :ok
  end

  defp flush_render_messages do
    receive do
      :poll_render -> flush_render_messages()
      :render_complete -> flush_render_messages()
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
      aspect_ratio: "16:9",
      duration: "5s",
      quality: "pro",
      motion_intensity: 3,
      scenes: [],
      current_scene: 0,
      total_scenes: 0,
      video_count_before: 0,
      errors: [],
      timer_ref: nil,
      started_at: nil
    }
  end
end
