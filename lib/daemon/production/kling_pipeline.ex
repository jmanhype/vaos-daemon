defmodule Daemon.Production.KlingPipeline do
  @moduledoc """
  Production engine that autonomously produces films through Kling AI.

  Receives the same production brief as FilmPipeline and SoraPipeline and drives
  the full pipeline: window setup, prompt submission on Kling's current
  `kling.ai/app` workspace, optional reference image upload for scene 1, render
  polling, and Extend chains for scenes 2-N.

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
  @kling_url "https://kling.ai/app/video/new?ac=1"
  @kling_motion_url "https://kling.ai/app/video-motion-control/new"

  @render_wait_ms 120_000
  @post_navigate_ms 5_000
  @post_paste_ms 1_500
  @post_submit_ms 3_000
  @post_upload_ms 8_000
  @post_click_ms 3_000
  @poll_interval_ms 5_000

  # ── Kling DOM selector JS fragments ──────────────────────────────────
  # These target Kling AI's current React SPA DOM patterns.

  @standard_ready_js ~S"""
  (function(){
    var prompt=document.querySelector('.tiptap.ProseMirror[contenteditable="true"]') || document.querySelector('div[role="textbox"]') || document.querySelector('textarea');
    return prompt ? 'ready' : '';
  })()
  """

  @upload_input_ready_js ~S"""
  (function(){
    return document.querySelector('input.el-upload__input[type="file"]') || document.querySelector('input[type="file"]') ? 'ready' : '';
  })()
  """

  @dismiss_modal_js ~S"""
  (function(){
    var buttons=Array.from(document.querySelectorAll('[role="dialog"] button, .el-dialog__wrapper button, .el-overlay-dialog button, .el-message-box button, button'));
    for (var i=0;i<buttons.length;i++) {
      var text=(buttons[i].innerText||buttons[i].textContent||'').trim().toLowerCase();
      if (text==='got it' || text==='ok' || text==='i know') {
        buttons[i].click();
        return 'dismissed:' + text;
      }
    }
    return 'no_modal';
  })()
  """

  # Find the prompt textarea
  @prompt_selector_js ~S"""
  document.querySelector('.tiptap.ProseMirror[contenteditable="true"]') || document.querySelector('div[role="textbox"]') || document.querySelector('textarea[placeholder*="prompt"]') || document.querySelector('textarea[placeholder*="Prompt"]') || document.querySelector('textarea[placeholder*="describe"]') || document.querySelector('textarea[placeholder*="Describe"]') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]')
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

  # Check if a video is still rendering (look for progress indicators)
  @check_rendering_js ~S"""
  var indicators=document.querySelectorAll('[class*="progress"],[class*="loading"],[class*="generating"],[class*="pending"],.ant-spin,.loading-spinner');var text=document.body.innerText.toLowerCase();var isRendering=(indicators.length>0)||(text.indexOf('generating')>-1&&text.indexOf('in queue')>-1)||(text.indexOf('processing')>-1);isRendering?'rendering':'done'
  """

  # ── Motion Control selectors ────────────────────────────────────
  # The motion control page at kling.ai/app/video-motion-control/new
  # has: upload[0] for .mp4/.mov (motion video), upload[1] for .jpg/.png
  # (character image), a tiptap ProseMirror prompt editor, and a Generate button.

  # Focus the tiptap ProseMirror prompt editor (Kling motion control uses contenteditable)
  @motion_prompt_js ~S"""
  var el = document.querySelector('.tiptap.ProseMirror[contenteditable="true"]');
  if (el) {
    var r = el.getBoundingClientRect();
    ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t) {
      el.dispatchEvent(new PointerEvent(t, {
        bubbles: true, cancelable: true,
        clientX: r.x + r.width/2, clientY: r.y + r.height/2,
        pointerId: 1
      }));
    });
    el.focus();
    Math.round(r.x + r.width/2) + ',' + Math.round(r.y + r.height/2);
  } else { '0,0'; }
  """

  # Click the Generate button on motion control page
  @motion_generate_js ~S"""
  var btn = document.querySelector('button.generic-button.critical.big.button-pay');
  if (btn) {
    var r = btn.getBoundingClientRect();
    ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t) {
      btn.dispatchEvent(new PointerEvent(t, {
        bubbles: true, cancelable: true,
        clientX: r.x + r.width/2, clientY: r.y + r.height/2,
        pointerId: 1
      }));
    });
    'generate_clicked';
  } else { 'generate_not_found'; }
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
    - `:mode` — optional, `:image_to_video` (default) or `:motion_control`
    - `:motion_video` — path to motion reference video (required for `:motion_control`)
    - `:ingredients` — map of `%{"filename" => "/path"}` ingredient images (motion control)

  ## Motion Control Usage

      KlingPipeline.produce(%{
        title: "Kinuk Itta",
        mode: :motion_control,
        motion_video: "/tmp/kling_motion_refs/man_talking_camera.mp4",
        ingredients: %{
          "elder_man.jpg" => "/tmp/ingredients/elder.jpg",
          "cabin.jpg" => "/tmp/ingredients/cabin.jpg"
        },
        scenes: [
          %{title: "Hook", prompt: "Warm cabin interior, golden hour light", ingredient: "elder_man.jpg"},
          %{title: "Kitchen", prompt: "Rustic kitchen, morning light", ingredient: "elder_man.jpg"}
        ]
      })
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
    mode = Map.get(brief, :mode, :image_to_video)

    # Build ingredients map (motion control mode)
    ingredients = Map.get(brief, :ingredients, %{})

    ingredients =
      if ingredients == %{} && Map.get(brief, :reference_image) do
        %{"reference.jpg" => brief.reference_image}
      else
        ingredients
      end

    new_state = %{
      state: :acquiring,
      mode: mode,
      title: Map.get(brief, :title, "Untitled"),
      character_bible: Map.get(brief, :character_bible, ""),
      reference_image: Map.get(brief, :reference_image, nil),
      motion_video: Map.get(brief, :motion_video, nil),
      ingredients: ingredients,
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
      scene_started_at: nil,
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
    case state.mode do
      :motion_control ->
        # Navigate directly to motion control page
        BrowserPipeline.navigate(@window_name, @kling_motion_url)
        Process.sleep(@post_navigate_ms)
        BrowserPipeline.execute_js(@window_name, @dismiss_modal_js)

        url = BrowserPipeline.get_url(@window_name)
        Logger.info("[KlingPipeline] Navigated to Motion Control (URL: #{url})")

        {:noreply, %{state | state: :submitting}, {:continue, :submit_motion_scene}}

      _ ->
        # Standard prompt workspace
        BrowserPipeline.navigate(@window_name, @kling_url)
        Process.sleep(@post_navigate_ms)
        BrowserPipeline.wait_for(@window_name, @standard_ready_js, 30_000, 1_000)
        dismiss_result = BrowserPipeline.execute_js(@window_name, @dismiss_modal_js)

        url = BrowserPipeline.get_url(@window_name)
        Logger.info("[KlingPipeline] Navigated to Kling generate workspace (URL: #{url})")
        Logger.info("[KlingPipeline] Modal dismiss result: #{dismiss_result}")

        if state.reference_image && File.exists?(state.reference_image) do
          {:noreply, %{state | state: :uploading_reference}, {:continue, :upload_reference}}
        else
          {:noreply, %{state | state: :submitting_first}, {:continue, :configure_settings}}
        end
    end
  end

  def handle_continue(:upload_reference, state) do
    Logger.info("[KlingPipeline] Uploading reference image: #{state.reference_image}")
    BrowserPipeline.execute_js(@window_name, @dismiss_modal_js)
    BrowserPipeline.wait_for(@window_name, @upload_input_ready_js, 15_000, 500)

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

    Logger.debug(
      "[KlingPipeline] Set motion intensity #{state.motion_intensity}: #{intensity_result}"
    )

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

    new_state = %{
      state
      | state: :rendering,
        current_scene: 1,
        video_count_before: count_before,
        scene_started_at: DateTime.utc_now()
    }

    new_state = schedule_render_poll(new_state)
    {:noreply, new_state}
  end

  # ── Motion Control Scene Submission ──────────────────────────────

  def handle_continue(:submit_motion_scene, state) do
    scene = Enum.at(state.scenes, state.current_scene)
    scene_num = state.current_scene + 1

    Logger.info(
      "[KlingPipeline] Motion control scene #{scene_num}/#{state.total_scenes}: #{scene[:title]}"
    )

    # Navigate to motion control page (fresh for each scene)
    if state.current_scene > 0 do
      BrowserPipeline.navigate(@window_name, @kling_motion_url)
      Process.sleep(@post_navigate_ms)
    end

    # Step 1: Upload motion reference video (upload input index 0: .mp4/.mov)
    if state.motion_video do
      Logger.info("[KlingPipeline] Uploading motion video: #{state.motion_video}")
      upload_to_input(state.motion_video, 0)
      Process.sleep(@post_upload_ms)
    end

    # Step 2: Upload character image (upload input index 1: .jpg/.png)
    # Use per-scene ingredient or fall back to reference_image
    ingredient_key = Map.get(scene, :ingredient) || Map.get(scene, "ingredient")

    character_image =
      cond do
        ingredient_key && Map.has_key?(state.ingredients, ingredient_key) ->
          Map.get(state.ingredients, ingredient_key)

        state.reference_image ->
          state.reference_image

        true ->
          nil
      end

    if character_image && File.exists?(character_image) do
      Logger.info("[KlingPipeline] Uploading character image: #{character_image}")
      upload_to_input(character_image, 1)
      Process.sleep(@post_upload_ms)
    end

    # Step 3: Paste prompt into tiptap ProseMirror editor
    prompt = build_motion_prompt(state, scene)
    count_before = get_video_count()
    coords = BrowserPipeline.execute_js(@window_name, @motion_prompt_js)

    case String.split(String.trim(coords), ",") do
      [x_str, y_str] ->
        x = String.to_integer(x_str)
        y = String.to_integer(y_str)

        if x > 0 and y > 0 do
          BrowserPipeline.focus_and_click(@window_name, x, y + 112)
        end

      _ ->
        :ok
    end

    Process.sleep(300)
    File.write!("/tmp/osa_browser_paste.txt", prompt)
    System.cmd("bash", ["-c", "cat /tmp/osa_browser_paste.txt | pbcopy"])

    BrowserPipeline.osascript([
      ~s(tell application "Google Chrome"),
      ~s(  set targetWindow to first window whose given name is "#{@window_name}"),
      ~s(  set index of targetWindow to 1),
      ~s(end tell),
      ~s(delay 0.3),
      ~s(tell application "System Events"),
      ~s(  keystroke "v" using {command down}),
      ~s(end tell)
    ])

    Process.sleep(@post_paste_ms)

    # Step 4: Click Generate button
    gen_result = BrowserPipeline.execute_js(@window_name, @motion_generate_js)
    Logger.info("[KlingPipeline] Motion generate result: #{gen_result}")
    Process.sleep(@post_submit_ms)

    broadcast(:scene_submitted, %{scene: scene_num, title: scene[:title], mode: :motion_control})
    Logger.info("[KlingPipeline] Motion scene #{scene_num} submitted (awaiting render)")

    new_state = %{
      state
      | state: :rendering,
        current_scene: scene_num,
        video_count_before: count_before,
        scene_started_at: DateTime.utc_now()
    }

    new_state = schedule_render_poll(new_state)
    {:noreply, new_state}
  end

  def handle_continue(:post_render, state) do
    Logger.info("[KlingPipeline] Render complete for scene #{state.current_scene}")

    if state.current_scene >= state.total_scenes do
      {:noreply, state, {:continue, :complete}}
    else
      case state.mode do
        :motion_control ->
          # Motion control: each scene is independent (fresh page)
          {:noreply, %{state | state: :submitting}, {:continue, :submit_motion_scene}}

        _ ->
          # Standard: extend from previous scene
          {:noreply, %{state | state: :extending}, {:continue, :extend_next_scene}}
      end
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
      count_before = get_video_count()

      extend_result =
        case BrowserPipeline.execute_js(@window_name, @extend_button_js) do
          "extend_not_found" = initial ->
            Logger.info("[KlingPipeline] Extend button result: #{initial}")
            Logger.info("[KlingPipeline] Extend not found — trying via My Creatives")
            BrowserPipeline.execute_js(@window_name, @navigate_creatives_js)
            Process.sleep(@post_click_ms)
            BrowserPipeline.execute_js(@window_name, @click_first_video_js)
            Process.sleep(@post_click_ms)
            retry_result = BrowserPipeline.execute_js(@window_name, @extend_button_js)
            Logger.info("[KlingPipeline] Extend retry result: #{retry_result}")
            retry_result

          result ->
            Logger.info("[KlingPipeline] Extend button result: #{result}")
            result
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
      else
        Logger.warning(
          "[KlingPipeline] No extend button — generating scene #{scene_num} independently"
        )

        generate_independent_scene(state, scene, scene_num)
      end

      broadcast(:scene_submitted, %{scene: scene_num, title: scene.title})

      new_state = %{
        state
        | state: :rendering,
          current_scene: scene_num,
          video_count_before: count_before,
          scene_started_at: DateTime.utc_now()
      }

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

      scene_elapsed_ms(state) >= @render_wait_ms ->
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
    BrowserPipeline.wait_for(@window_name, @standard_ready_js, 30_000, 1_000)
    BrowserPipeline.execute_js(@window_name, @dismiss_modal_js)

    # Re-upload reference image if available
    if state.reference_image && File.exists?(state.reference_image) do
      BrowserPipeline.wait_for(@window_name, @upload_input_ready_js, 15_000, 500)
      BrowserPipeline.upload_file(@window_name, state.reference_image)
      Process.sleep(@post_upload_ms)
    end

    # Paste and submit
    prompt = build_prompt(state, scene)
    BrowserPipeline.focus_and_paste(@window_name, @prompt_selector_js, prompt)
    Process.sleep(@post_paste_ms)

    gen_result = BrowserPipeline.execute_js(@window_name, @generate_js)
    Logger.info("[KlingPipeline] Independent scene #{scene_num} generate: #{gen_result}")
    Process.sleep(@post_submit_ms)
  end

  defp upload_to_input(file_path, input_index) do
    # Build upload JS targeting a specific input[type=file] by index
    ext = Path.extname(file_path) |> String.downcase() |> String.trim_leading(".")

    mime =
      case ext do
        "jpg" -> "image/jpeg"
        "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "mp4" -> "video/mp4"
        "mov" -> "video/quicktime"
        _ -> "application/octet-stream"
      end

    fname = Path.basename(file_path)

    script = """
    #!/bin/bash
    B64=$(base64 -i "$1" | tr -d '\\n')
    cat > /tmp/osa_motion_upload.js << JSEOF
    var b64 = "$B64";
    var binary = atob(b64);
    var arr = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) arr[i] = binary.charCodeAt(i);
    var file = new File([arr], "#{fname}", {type: "#{mime}"});
    var dt = new DataTransfer();
    dt.items.add(file);
    var inputs = document.querySelectorAll('input.el-upload__input[type="file"]');
    if (inputs.length > #{input_index}) {
      inputs[#{input_index}].files = dt.files;
      inputs[#{input_index}].dispatchEvent(new Event("change", {bubbles: true}));
      "uploaded " + file.size + " bytes to input #{input_index}";
    } else {
      "no input at index #{input_index}, found " + inputs.length;
    }
    JSEOF
    """

    File.write!("/tmp/osa_build_motion_upload.sh", script)
    System.cmd("bash", ["/tmp/osa_build_motion_upload.sh", file_path])

    BrowserPipeline.execute_js_file(@window_name, "/tmp/osa_motion_upload.js")
  end

  defp build_motion_prompt(state, scene) do
    # Motion control prompts describe scene/atmosphere ONLY, not action
    # (the motion reference video handles all movement)
    parts = []
    parts = if state.preset != "", do: parts ++ ["[#{state.preset}]"], else: parts
    parts = parts ++ [scene[:prompt] || scene.prompt]

    prompt = Enum.join(parts, "\n\n")

    if String.length(prompt) > 2500 do
      Logger.warning("[KlingPipeline] Motion prompt truncated to 2500 chars")
      String.slice(prompt, 0, 2500)
    else
      prompt
    end
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
      Logger.warning(
        "[KlingPipeline] Prompt truncated from #{String.length(prompt)} to 2500 chars"
      )

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

  defp scene_elapsed_ms(state) do
    case state.scene_started_at do
      nil -> elapsed_ms(state)
      started -> DateTime.diff(DateTime.utc_now(), started, :millisecond)
    end
  end

  defp broadcast(event, data) do
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
      mode: :image_to_video,
      title: nil,
      character_bible: nil,
      reference_image: nil,
      motion_video: nil,
      ingredients: %{},
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
      scene_started_at: nil,
      started_at: nil
    }
  end
end
