defmodule Daemon.Production.FilmPipeline do
  @moduledoc """
  Core production engine that autonomously produces films through Google Flow.

  Supports multi-ingredient per-scene briefs: each scene declares which
  ingredient images to attach. Ingredients are uploaded once at project
  creation, then selectively attached per-scene via the Flow picker.

  Backward compatible: if `reference_image` is set with no `ingredients` map,
  behaves identically to the original single-reference pipeline.

  ## Usage

      FilmPipeline.produce(%{
        title: "Kinuk Itta",
        character_bible: "KINUK: Elderly man...",
        preset: "Documentary Realism",
        ingredients: %{
          "elder_man.jpg" => "/tmp/ingredients/elder.jpg",
          "kitchen.jpg" => "/tmp/ingredients/kitchen.jpg"
        },
        scenes: [
          %{title: "Hook", prompt: "...", ingredients: ["elder_man.jpg"]},
          %{title: "Kitchen", prompt: "...", ingredients: ["elder_man.jpg", "kitchen.jpg"]}
        ]
      })

      FilmPipeline.status()
      #=> %{state: :submitting, current_scene: 2, total_scenes: 3, ...}
  """
  use GenServer

  require Logger

  alias Daemon.Production.{ChromeSlot, FlowRateLimiter, ChromeHealth}

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

  @spec produce(map()) :: :ok | {:error, :already_producing}
  def produce(brief) when is_map(brief) do
    GenServer.call(__MODULE__, {:produce, brief})
  end

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec abort() :: :ok
  def abort, do: GenServer.call(__MODULE__, :abort)

  # ── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, initial_state()}

  @impl true
  def handle_call({:produce, brief}, _from, %{state: :idle} = _state) do
    scenes = Map.get(brief, :scenes, [])

    # Build ingredients map — legacy compat wraps reference_image
    ingredients = Map.get(brief, :ingredients, %{})

    ingredients =
      if ingredients == %{} && Map.get(brief, :reference_image) do
        %{"reference.jpg" => brief.reference_image}
      else
        ingredients
      end

    new_state = %{
      state: :acquiring,
      title: Map.get(brief, :title, "Untitled"),
      character_bible: Map.get(brief, :character_bible, ""),
      reference_image: Map.get(brief, :reference_image, nil),
      ingredients: ingredients,
      preset: Map.get(brief, :preset, ""),
      scenes: scenes,
      current_scene: 0,
      total_scenes: length(scenes),
      project_url: nil,
      errors: [],
      timer_ref: nil,
      started_at: DateTime.utc_now()
    }

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
     {:continue, :upload_ingredients}}
  end

  def handle_continue(:upload_ingredients, state) do
    if map_size(state.ingredients) > 0 do
      Enum.each(state.ingredients, fn {filename, path} ->
        if File.exists?(path) do
          Logger.info("[FilmPipeline] Uploading ingredient: #{filename}")
          upload_ingredient(path, filename)
          Process.sleep(5_000)
        else
          Logger.warning("[FilmPipeline] Ingredient file not found: #{path}")
        end
      end)

      Logger.info("[FilmPipeline] All ingredients uploaded (#{map_size(state.ingredients)})")
    else
      Logger.info("[FilmPipeline] No ingredients to upload")
    end

    {:noreply, %{state | state: :submitting}, {:continue, :submit_scene}}
  end

  def handle_continue(:submit_scene, state) do
    scene = Enum.at(state.scenes, state.current_scene)
    scene_num = state.current_scene + 1
    mode = Map.get(scene, :mode, "new")

    Logger.info(
      "[FilmPipeline] #{String.upcase(mode)} scene #{scene_num}/#{state.total_scenes}: #{scene[:title]}"
    )

    if mode == "extend" do
      # Extend: click Extend button, attach any new ingredients, paste prompt
      FlowRateLimiter.check_and_wait(:flow_extend)
      click_extend()
      Process.sleep(@post_extend_click_ms)

      # Attach ingredients for the extend (enables prop swaps)
      scene_ingredients = Map.get(scene, :ingredients, [])

      Enum.each(scene_ingredients, fn filename ->
        Logger.info("[FilmPipeline] Attaching ingredient for extend: #{filename}")
        open_ingredient_picker()
        Process.sleep(3_000)
        click_ingredient_by_name(filename)
        Process.sleep(2_000)
      end)

      prompt = build_prompt(state, scene)
      focus_and_paste(prompt)
      Process.sleep(@post_paste_ms)
      click_submit()
      Process.sleep(@post_submit_ms)
    else
      # New scene: full ingredient attachment + prompt
      scene_ingredients = Map.get(scene, :ingredients, [])

      scene_ingredients =
        if scene_ingredients == [] && state.reference_image do
          ["reference.jpg"]
        else
          scene_ingredients
        end

      FlowRateLimiter.check_and_wait(:flow_submit)

      Enum.each(scene_ingredients, fn filename ->
        Logger.info("[FilmPipeline] Attaching ingredient: #{filename}")
        open_ingredient_picker()
        Process.sleep(3_000)
        click_ingredient_by_name(filename)
        Process.sleep(2_000)
      end)

      prompt = build_prompt(state, scene)
      focus_and_paste(prompt)
      Process.sleep(@post_paste_ms)
      click_submit()
      Process.sleep(@post_submit_ms)
    end

    broadcast(:scene_submitted, %{scene: scene_num, title: scene[:title], mode: mode})
    Logger.info("[FilmPipeline] Scene #{scene_num} submitted as #{mode} (awaiting render)")

    new_state = %{state | state: :rendering, current_scene: scene_num}
    new_state = schedule_render_complete(new_state)
    {:noreply, new_state}
  end

  def handle_continue(:post_render, state) do
    current_scene = Enum.at(state.scenes, state.current_scene - 1)
    current_mode = Map.get(current_scene || %{}, :mode, "new")
    Logger.info("[FilmPipeline] Render complete for scene #{state.current_scene} (was #{current_mode})")

    if state.current_scene >= state.total_scenes do
      # All done
      {:noreply, state, {:continue, :complete}}
    else
      next_scene = Enum.at(state.scenes, state.current_scene)
      next_mode = Map.get(next_scene || %{}, :mode, "new")

      if next_mode == "extend" do
        # Next is extend — click tile to enter edit view, then extend from there
        click_first_tile()
        Process.sleep(@post_tile_click_ms)
        {:noreply, %{state | state: :submitting}, {:continue, :submit_scene}}
      else
        # Next is new — click tile (to save), then navigate back to project root
        click_first_tile()
        Process.sleep(@post_tile_click_ms)
        navigate_to_project(state.project_url)
        Process.sleep(@post_navigate_ms)
        {:noreply, %{state | state: :submitting}, {:continue, :submit_scene}}
      end
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
  def handle_info(:render_complete, %{state: :rendering} = state) do
    {:noreply, state, {:continue, :post_render}}
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

  defp navigate_to_project(project_url) do
    base_url = String.replace(project_url, ~r|/edit/.*|, "")

    osascript([
      "tell application \"Google Chrome\"",
      "set URL of active tab of front window to \"#{base_url}\"",
      "end tell"
    ])
  end

  defp create_new_project do
    execute_js(
      "document.querySelector(\"#__next > div.sc-c7ee1759-1.crzReP > div > div > button\").click(); \"new\""
    )
  end

  @focus_js ~S|var el=document.querySelector("[contenteditable='true']");if(el){var r=el.getBoundingClientRect();['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){el.dispatchEvent(new PointerEvent(t,{bubbles:true,cancelable:true,clientX:r.x+r.width/2,clientY:r.y+r.height/2,pointerId:1}))});el.focus();'ok'}else{'fail'}|

  @tile_js ~S|var imgs=document.querySelectorAll('img[alt="Video thumbnail"]');if(imgs[0]){imgs[0].scrollIntoView();imgs[0].parentElement.click();'clicked'}else{'no tiles'}|

  @plus_button_js "var btns=document.querySelectorAll('button');var btn=null;for(var i=0;i<btns.length;i++){if(btns[i].textContent.trim()==='add_2Create'&&btns[i].getBoundingClientRect().y>700){btn=btns[i];break;}}if(btn){var r=btn.getBoundingClientRect();['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){btn.dispatchEvent(new PointerEvent(t,{bubbles:true,cancelable:true,clientX:r.x+r.width/2,clientY:r.y+r.height/2,pointerId:1}))});'opened'}else{'not found'}"

  @extend_js ~S|var btns=document.querySelectorAll('button');for(var i=0;i<btns.length;i++){if(btns[i].textContent.indexOf('Ext')>-1&&btns[i].getBoundingClientRect().y>800){var r=btns[i].getBoundingClientRect();['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){btns[i].dispatchEvent(new PointerEvent(t,{bubbles:true,cancelable:true,clientX:r.x+r.width/2,clientY:r.y+r.height/2,pointerId:1}))});break;}}'clicked extend'|

  defp focus_and_paste(text) do
    execute_js(@focus_js)

    coords =
      execute_js(
        "var el=document.querySelector('[contenteditable]');if(el){var r=el.getBoundingClientRect();Math.round(r.x+r.width/2)+','+Math.round(r.y+r.height/2)}else{'0,0'}"
      )

    case String.split(String.trim(coords), ",") do
      [x_str, y_str] ->
        x = String.to_integer(x_str)
        y = String.to_integer(y_str)
        System.cmd("cliclick", ["c:#{x},#{y + 112}"])

      _ ->
        :ok
    end

    Process.sleep(300)

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
    osascript([
      "tell application \"Google Chrome\" to activate",
      "delay 0.3",
      "tell application \"System Events\"",
      "key code 36",
      "end tell"
    ])
  end

  defp click_first_tile, do: execute_js(@tile_js)

  defp click_extend, do: execute_js(@extend_js)

  defp open_ingredient_picker, do: execute_js(@plus_button_js)

  defp click_ingredient_by_name(filename) do
    js = """
    var img = document.querySelector('img[alt="#{filename}"]');
    if (img) {
      var el = img.closest('.sc-903adef0-11') || img.parentElement;
      var r = el.getBoundingClientRect();
      Math.round(r.x + r.width/2) + ',' + Math.round(r.y + r.height/2);
    } else { 'not_found'; }
    """

    File.write!("/tmp/osa_find_picker.js", String.trim(js))

    result =
      osascript([
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
        Logger.info("[FilmPipeline] Clicking ingredient #{filename} at screen #{x},#{screen_y}")
        System.cmd("cliclick", ["c:#{x},#{screen_y}"])

      _ ->
        Logger.warning("[FilmPipeline] Could not find #{filename} in picker: #{result}")
    end
  end

  defp get_project_url do
    osascript(["tell application \"Google Chrome\" to get URL of active tab of front window"])
  end

  # Ingredient upload — inject image via file input with custom filename
  defp upload_ingredient(image_path, filename \\ "reference.jpg") do
    script = """
    #!/bin/bash
    B64=$(base64 -i "$1" | tr -d '\n')
    FNAME="$2"
    cat > /tmp/osa_upload_ingredient.js << JSEOF
    var b64 = "$B64";
    var binary = atob(b64);
    var arr = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) arr[i] = binary.charCodeAt(i);
    var file = new File([arr], "$FNAME", {type: "image/jpeg"});
    var dt = new DataTransfer();
    dt.items.add(file);
    var input = document.querySelector("input[type=file]");
    input.files = dt.files;
    input.dispatchEvent(new Event("change", {bubbles: true}));
    "uploaded " + file.size + " bytes as " + "$FNAME";
    JSEOF
    """

    File.write!("/tmp/osa_build_upload.sh", script)
    System.cmd("bash", ["/tmp/osa_build_upload.sh", image_path, filename])

    osascript([
      ~s(set jsCode to do shell script "cat /tmp/osa_upload_ingredient.js"),
      ~s(tell application "Google Chrome"),
      "tell active tab of front window",
      "execute javascript jsCode",
      "end tell",
      "end tell"
    ])
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

  defp build_prompt(state, scene) do
    parts = []
    parts = if state.preset != "", do: parts ++ ["[#{state.preset}]"], else: parts
    parts = if state.character_bible != "", do: parts ++ [state.character_bible], else: parts
    parts = parts ++ [scene.prompt]
    Enum.join(parts, "\n\n")
  end

  defp schedule_render_complete(state) do
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
      Daemon.PubSub,
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
        Logger.error(
          "[FilmPipeline] Verify #{step} FAILED: URL #{url} does not contain #{expected_in_url}"
        )

        :ok
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
      ingredients: %{},
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
