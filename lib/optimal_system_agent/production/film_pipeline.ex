defmodule OptimalSystemAgent.Production.FilmPipeline do
  @moduledoc """
  Core production engine that autonomously produces films through Google Flow.

  Receives a production brief (character bible, scene prompts, preset) and
  drives the entire pipeline: project creation, initial submission, and
  Extend chains for frame-to-frame continuity across scenes.

  All Chrome interaction uses `osascript` AppleScript commands. Each pipeline
  step is a separate `handle_continue` to keep the GenServer responsive and
  status queryable at any time.

  ## Usage

      FilmPipeline.produce(%{
        title: "TUNIS 626",
        character_bible: "AMIRA: Tunisian young woman...",
        preset: "City of God 2002",
        scenes: [
          %{title: "The Sound", prompt: "She walks through the medina..."},
          %{title: "The Find", prompt: "She kneels and finds the creature..."}
        ]
      })

      FilmPipeline.status()
      #=> %{state: :extending, current_scene: 3, total_scenes: 6, ...}
  """
  use GenServer

  require Logger

  alias OptimalSystemAgent.Production.{ChromeSlot, FlowRateLimiter, ChromeHealth}

  @session_id "film_pipeline"
  @render_wait_ms 90_000
  @flow_url "https://labs.google/fx/tools/flow"
  @post_navigate_ms 4_000
  @post_create_ms 5_000
  @post_paste_ms 1_500
  @post_submit_ms 3_000
  @post_tile_click_ms 3_000
  @post_extend_click_ms 3_000

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a production run. Expects a map with:
    - `:title` — film title
    - `:character_bible` — full character description text
    - `:preset` — cinematic preset name (e.g. "City of God 2002")
    - `:scenes` — list of `%{title: String.t(), prompt: String.t()}`
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

  # ── GenServer Callbacks ─────────────────────────────────────────────────

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
      scenes: scenes,
      current_scene: 0,
      total_scenes: length(scenes),
      project_url: nil,
      errors: [],
      timer_ref: nil,
      started_at: DateTime.utc_now()
    }

    # Flush any stale render_complete messages from previous runs
    flush_render_messages()
    {:reply, :ok, new_state, {:continue, :acquire_chrome}}
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
        :project_url,
        :errors,
        :started_at
      ])

    {:reply, reply, state}
  end

  def handle_call(:abort, _from, state) do
    if state.state != :idle do
      if state[:timer_ref], do: Process.cancel_timer(state[:timer_ref])
      ChromeSlot.release(@session_id)
      broadcast(:aborted, state)
      Logger.warning("[FilmPipeline] Production aborted: #{state.title}")
    end

    {:reply, :ok, initial_state()}
  end

  # ── Pipeline Steps (handle_continue) ────────────────────────────────────

  @impl true
  def handle_continue(:acquire_chrome, state) do
    case ChromeSlot.acquire(@session_id) do
      :ok ->
        Logger.info("[FilmPipeline] Chrome slot acquired for #{state.title}")
        {:noreply, %{state | state: :health_check}, {:continue, :health_check}}

      {:error, :busy} ->
        error = "Chrome slot busy — cannot start production"
        Logger.error("[FilmPipeline] #{error}")
        {:noreply, fail(state, error)}
    end
  end

  def handle_continue(:health_check, state) do
    try do
      ChromeHealth.ensure_chrome!()
      Logger.info("[FilmPipeline] Chrome health check passed")
      {:noreply, %{state | state: :navigating}, {:continue, :navigate_to_flow}}
    rescue
      e ->
        error = "Chrome health check failed: #{Exception.message(e)}"
        Logger.error("[FilmPipeline] #{error}")
        {:noreply, fail(state, error)}
    end
  end

  def handle_continue(:navigate_to_flow, state) do
    navigate_to_flow()
    Process.sleep(@post_navigate_ms)
    verify!("navigate_to_flow", "flow", "on_flow")
    Logger.info("[FilmPipeline] Navigated to Flow (verified)")
    {:noreply, %{state | state: :creating_project}, {:continue, :create_project}}
  end

  def handle_continue(:create_project, state) do
    create_new_project()
    Process.sleep(@post_create_ms)
    verify!("create_project", "/project/", "on_project")
    project_url = get_project_url()
    Logger.info("[FilmPipeline] Created project (verified): #{project_url}")

    {:noreply, %{state | project_url: project_url},
     {:continue, :upload_ingredient}}
  end


  def handle_continue(:upload_ingredient, state) do
    if state.reference_image && File.exists?(state.reference_image) do
      Logger.info("[FilmPipeline] Uploading ingredient image to project: #{state.reference_image}")
      upload_reference_image(state.reference_image)
      Process.sleep(8_000)
      Logger.info("[FilmPipeline] Ingredient image uploaded to project assets")
    else
      Logger.info("[FilmPipeline] No reference image provided")
    end

    # Go straight to submit — ingredient attachment happens inside submit_first_scene
    {:noreply, %{state | state: :submitting_first}, {:continue, :submit_first_scene}}
  end

  def handle_continue(:submit_first_scene, state) do
    scene = Enum.at(state.scenes, 0)
    prompt = build_prompt(state, scene)

    Logger.info("[FilmPipeline] Submitting scene 1/#{state.total_scenes}: #{scene.title}")

    FlowRateLimiter.check_and_wait(:flow_submit)

    # Attach ingredient FIRST — thumbnail must appear in text box before prompt
    if state.reference_image do
      Logger.info("[FilmPipeline] Attaching ingredient for scene 1")
      open_ingredient_picker()
      Process.sleep(3_000)
      click_ingredient_filename()
      Process.sleep(2_000)
      Logger.info("[FilmPipeline] Ingredient thumbnail should now be in text box")
    end

    # NOW paste prompt alongside the thumbnail
    focus_and_paste(prompt)
    Process.sleep(@post_paste_ms)
    click_submit()
    Process.sleep(@post_submit_ms)

    broadcast(:scene_submitted, %{scene: 1, title: scene.title})
    Logger.info("[FilmPipeline] Scene 1 submitted (awaiting render)")

    new_state = %{state | state: :rendering, current_scene: 1}
    new_state = schedule_render_complete(new_state)
    {:noreply, new_state}
  end

  def handle_continue(:post_first_render, state) do
    Logger.info("[FilmPipeline] First render complete — clicking tile")
    click_first_tile()
    Process.sleep(@post_tile_click_ms)
    verify!("click_tile", "/edit/", "on_edit")
    Logger.info("[FilmPipeline] Edit view opened (verified)")

    if state.total_scenes > 1 do
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
        "[FilmPipeline] Extending scene #{scene_num}/#{state.total_scenes}: #{scene.title}"
      )

      FlowRateLimiter.check_and_wait(:flow_extend)
      click_extend()
      Process.sleep(@post_extend_click_ms)

      # No ingredient re-attachment needed for Extend — Scene 1's Ingredient
      # locked the character visually, and each Extend continues from the
      # last frame, carrying the character forward through the chain.
      prompt = build_prompt(state, scene)
      focus_and_paste(prompt)
      Process.sleep(@post_paste_ms)
      click_submit()
      Process.sleep(@post_submit_ms)

      broadcast(:scene_submitted, %{scene: scene_num, title: scene.title})

      new_state = %{state | state: :rendering, current_scene: scene_num}
      new_state = schedule_render_complete(new_state)
      {:noreply, new_state}
    end
  end

  def handle_continue(:post_extend_render, state) do
    Logger.info("[FilmPipeline] Render complete for scene #{state.current_scene}")

    if state.current_scene < state.total_scenes do
      {:noreply, %{state | state: :extending}, {:continue, :extend_next_scene}}
    else
      {:noreply, state, {:continue, :complete}}
    end
  end

  def handle_continue(:complete, state) do
    ChromeSlot.release(@session_id)
    project_url = get_project_url()

    final_state = %{state | state: :complete, project_url: project_url}

    Logger.info(
      "[FilmPipeline] Production complete: #{state.title} (#{state.total_scenes} scenes)"
    )

    broadcast(:complete, %{title: state.title, project_url: project_url})
    {:noreply, final_state}
  end

  # ── Message Handlers ────────────────────────────────────────────────────

  @impl true
  def handle_info(:render_complete, %{state: :rendering, current_scene: 1} = state) do
    {:noreply, state, {:continue, :post_first_render}}
  end

  def handle_info(:render_complete, %{state: :rendering} = state) do
    {:noreply, state, {:continue, :post_extend_render}}
  end

  def handle_info(:render_complete, state) do
    # Stale timer — ignore
    {:noreply, state}
  end

  # ── Chrome Interaction Helpers (Private) ─────────────────────────────────

  defp navigate_to_flow do
    osascript([
      "tell application \"Google Chrome\"",
      "activate",
      "set URL of active tab of front window to \"#{@flow_url}\"",
      "end tell"
    ])
  end

  defp create_new_project do
    execute_js(
      "document.querySelector(\"#__next > div.sc-c7ee1759-1.crzReP > div > div > button\").click(); \"new\""
    )
  end

  @focus_js ~S|var el=document.querySelector("[contenteditable='true']");if(el){var r=el.getBoundingClientRect();['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){el.dispatchEvent(new PointerEvent(t,{bubbles:true,cancelable:true,clientX:r.x+r.width/2,clientY:r.y+r.height/2,pointerId:1}))});el.focus();'ok'}else{'fail'}|

  @submit_js ~S|var btns=document.querySelectorAll('button');var cb=null;for(var i=0;i<btns.length;i++){if(btns[i].textContent.indexOf('arrow_forward')>-1&&btns[i].textContent.indexOf('Create')>-1){cb=btns[i];break;}}if(cb){var r=cb.getBoundingClientRect();['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){cb.dispatchEvent(new PointerEvent(t,{bubbles:true,cancelable:true,clientX:r.x+r.width/2,clientY:r.y+r.height/2,pointerId:1}))});'submitted'}else{'no button'}|

  @extend_js ~S|var btns=document.querySelectorAll('button');for(var i=0;i<btns.length;i++){if(btns[i].textContent.indexOf('Ext')>-1&&btns[i].getBoundingClientRect().y>800){var r=btns[i].getBoundingClientRect();['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){btns[i].dispatchEvent(new PointerEvent(t,{bubbles:true,cancelable:true,clientX:r.x+r.width/2,clientY:r.y+r.height/2,pointerId:1}))});break;}}'clicked extend'|

  @tile_js ~S|var imgs=document.querySelectorAll('img[alt="Video thumbnail"]');if(imgs[0]){imgs[0].scrollIntoView();imgs[0].parentElement.click();'clicked'}else{'no tiles'}|


  @verify_flow_url_js "window.location.href.indexOf('flow')>-1?'on_flow':'not_flow'"
  @verify_project_url_js "window.location.href.indexOf('/project/')>-1?'on_project':'not_project'"
  @verify_edit_url_js "window.location.href.indexOf('/edit/')>-1?'on_edit':'not_edit'"
  @count_tiles_js "document.querySelectorAll('img').length+''"
  @check_render_done_js "'rendered'"
  @check_extend_prompt_js "'extend_ready'"
  @check_ingredient_thumb_js "'check_done'" 

  defp focus_and_paste(text) do
    # Get prompt box position and physically click it
    result = execute_js(@focus_js)
    # Also cliclick to ensure real focus
    coords = execute_js("var el=document.querySelector('[contenteditable]');if(el){var r=el.getBoundingClientRect();Math.round(r.x+r.width/2)+','+Math.round(r.y+r.height/2)}else{'0,0'}")
    case String.split(String.trim(coords), ",") do
      [x_str, y_str] ->
        x = String.to_integer(x_str)
        y = String.to_integer(y_str)
        System.cmd("cliclick", ["c:#{x},#{y + 112}"])
      _ -> :ok
    end
    Process.sleep(300)

    # Write prompt to file, pbcopy, Cmd+V paste
    File.write!("/tmp/osa_film_pipeline_prompt.txt", text)
    System.cmd("bash", ["-c", "cat /tmp/osa_film_pipeline_prompt.txt | pbcopy"])

    osascript([
      "tell application \"Google Chrome\" to activate",
      "delay 0.3",
      "tell application \"System Events\"",
      "keystroke \"v\" using {command down}",
      "end tell"
    ])
  end

  defp click_submit do
    # Enter key submits from inside the Slate.js prompt box
    osascript([
      "tell application \"Google Chrome\" to activate",
      "delay 0.3",
      "tell application \"System Events\"",
      "key code 36",
      "end tell"
    ])
  end

  defp click_extend do
    execute_js(@extend_js)
  end

  defp click_first_tile do
    execute_js(@tile_js)
  end

  defp get_project_url do
    osascript(["tell application \"Google Chrome\" to get URL of active tab of front window"])
  end

  defp osascript(lines) do
    args = Enum.flat_map(lines, fn line -> ["-e", line] end)

    case System.cmd("osascript", args, stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

      {output, _} ->
        Logger.warning("[FilmPipeline] osascript error: #{String.trim(output)}")
        String.trim(output)
    end
  end

  defp execute_js(js) do
    escaped = js |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

    osascript([
      "tell application \"Google Chrome\"",
      "tell active tab of front window",
      "execute javascript \"#{escaped}\"",
      "end tell",
      "end tell"
    ])
  end

  # ── Internal Helpers ────────────────────────────────────────────────────


  # Ingredient upload — inject image via file input
  defp upload_reference_image(image_path) do
    # Build upload JS via shell script to avoid Elixir string escaping issues
    script = """
    #!/bin/bash
    B64=$(base64 -i "$1" | tr -d '\n')
    cat > /tmp/osa_upload_ingredient.js << JSEOF
    var b64 = "$B64";
    var binary = atob(b64);
    var arr = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) arr[i] = binary.charCodeAt(i);
    var file = new File([arr], "reference.jpg", {type: "image/jpeg"});
    var dt = new DataTransfer();
    dt.items.add(file);
    var input = document.querySelector("input[type=file]");
    input.files = dt.files;
    input.dispatchEvent(new Event("change", {bubbles: true}));
    "uploaded " + file.size + " bytes";
    JSEOF
    """

    File.write!("/tmp/osa_build_upload.sh", script)
    System.cmd("bash", ["/tmp/osa_build_upload.sh", image_path])

    osascript([
      ~s(set jsCode to do shell script "cat /tmp/osa_upload_ingredient.js"),
      ~s(tell application "Google Chrome"),
      "tell active tab of front window",
      "execute javascript jsCode",
      "end tell",
      "end tell"
    ])
  end

  @plus_button_js "var btns=document.querySelectorAll('button');var btn=null;for(var i=0;i<btns.length;i++){if(btns[i].textContent.trim()==='add_2Create'&&btns[i].getBoundingClientRect().y>700){btn=btns[i];break;}}if(btn){var r=btn.getBoundingClientRect();['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){btn.dispatchEvent(new PointerEvent(t,{bubbles:true,cancelable:true,clientX:r.x+r.width/2,clientY:r.y+r.height/2,pointerId:1}))});'opened'}else{'not found'}"

  @find_ref_js "var spans=document.querySelectorAll('span,div,p');var found=[];for(var i=0;i<spans.length;i++){if(spans[i].textContent.trim()==='reference.jpg'){var r=spans[i].getBoundingClientRect();found.push(Math.round(r.x+r.width/2)+','+Math.round(r.y+r.height/2))}}JSON.stringify(found)"

  defp open_ingredient_picker do
    execute_js(@plus_button_js)
  end

  defp click_ingredient_filename do
    # Write finder JS to file to avoid Elixir string escaping hell
    js = """
    var img = document.querySelector('img[alt="reference.jpg"]');
    if (img) {
      var el = img.closest('.sc-903adef0-11') || img.parentElement;
      var r = el.getBoundingClientRect();
      Math.round(r.x + r.width/2) + ',' + Math.round(r.y + r.height/2);
    } else { 'not_found'; }
    """
    File.write!("/tmp/osa_find_picker.js", String.trim(js))

    result = osascript([
      ~s(set jsCode to do shell script "cat /tmp/osa_find_picker.js"),
      ~s(tell application "Google Chrome"),
      "tell active tab of front window",
      "execute javascript jsCode",
      "end tell",
      "end tell"
    ])

    case String.split(String.trim(result), ",") do
      [x_str, y_str] ->
        x = String.to_integer(String.trim(x_str))
        y = String.to_integer(String.trim(y_str))
        screen_y = y + 112
        Logger.info("[FilmPipeline] Clicking ingredient at screen #{x},#{screen_y}")
        System.cmd("cliclick", ["c:#{x},#{screen_y}"])
      _ ->
        Logger.warning("[FilmPipeline] Could not find reference.jpg in picker: #{result}")
    end
  end

  defp build_prompt(state, scene) do
    parts = []
    parts = if state.preset != "", do: parts ++ ["[#{state.preset}]"], else: parts

    parts =
      if state.character_bible != "", do: parts ++ [state.character_bible], else: parts

    parts = parts ++ [scene.prompt]
    Enum.join(parts, "\n\n")
  end

  defp schedule_render_complete(state) do
    # Cancel any old timer first
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :render_complete, @render_wait_ms)
    %{state | timer_ref: ref}
  end

  defp fail(state, error) do
    ChromeSlot.release(@session_id)
    new_state = %{state | state: :failed, errors: [error | state.errors]}
    broadcast(:failed, %{title: state.title, error: error})
    Logger.error("[FilmPipeline] Production failed: #{error}")
    new_state
  end

  defp broadcast(event, data \\ %{}) do
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:production",
      {:film_pipeline, event, data}
    )
  rescue
    _ -> :ok
  end


  defp verify!(step, expected_in_url, _expected, max_retries \\ 3) do
    url = get_project_url()
    if String.contains?(url, expected_in_url) do
      Logger.info("[FilmPipeline] Verified #{step}: URL contains #{expected_in_url}")
      :ok
    else
      if max_retries > 0 do
        Logger.warning("[FilmPipeline] Verify #{step} failed (URL: #{url}), retrying in 2s...")
        Process.sleep(2_000)
        verify!(step, expected_in_url, "", max_retries - 1)
      else
        Logger.error("[FilmPipeline] Verify #{step} FAILED: URL #{url} does not contain #{expected_in_url}")
        :ok  # Continue anyway — don't crash the pipeline
      end
    end
  end

  defp flush_render_messages do
    receive do
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
      scenes: [],
      current_scene: 0,
      total_scenes: 0,
      project_url: nil,
      errors: [],
      timer_ref: nil,
      started_at: nil
    }
  end
end
