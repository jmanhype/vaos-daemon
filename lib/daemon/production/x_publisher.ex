defmodule Daemon.Production.XPublisher do
  @moduledoc """
  Publishes content to X (Twitter) via Chrome automation on Mac Mini.

  Handles articles (with cover images and video), tweets, and threads.
  Uses osascript for DOM interaction and DataTransfer injection for file uploads.

  CRITICAL: NEVER restart Chrome or touch the Chrome profile.

  Pipeline steps are driven by Process.send_after/3 so the GenServer mailbox
  stays responsive between steps (status/abort work at any time).
  Long-running shell commands (video upload, clipboard copy) run inside
  Task.async so they never block the GenServer process.

  ## Usage

      XPublisher.publish_article(%{
        title: "My Article Title",
        html_path: "/tmp/article.html",
        cover_image_path: "/tmp/cover.jpg",
        video_path: "/tmp/video.mp4"
      })

      XPublisher.post_thread(%{
        tweets: ["Tweet 1 text", "Tweet 2 text"],
        media_path: "/tmp/video.mp4"
      })

      XPublisher.status()
  """
  use GenServer
  require Logger

  @name __MODULE__

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  def publish_article(params), do: GenServer.call(@name, {:publish_article, params})
  def post_thread(params), do: GenServer.call(@name, {:post_thread, params})
  def post_tweet(text, opts \\ []), do: GenServer.call(@name, {:post_tweet, text, opts})
  def status, do: GenServer.call(@name, :status)
  def abort, do: GenServer.call(@name, :abort)

  # ── Init ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, initial_state()}

  defp initial_state, do: %{state: :idle, step: nil, error: nil, result: nil, params: nil, task_ref: nil}

  # ── Dispatch ────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:publish_article, params}, _from, %{state: :idle} = state) do
    schedule_step(:art_navigate, 0)
    {:reply, :ok, %{state | state: :article, step: :navigate, params: params}}
  end

  def handle_call({:post_thread, params}, _from, %{state: :idle} = state) do
    schedule_step(:thread_navigate, 0)
    {:reply, :ok, %{state | state: :thread, step: :navigate, params: Map.put(params, :index, 0)}}
  end

  def handle_call({:post_tweet, text, opts}, _from, %{state: :idle} = state) do
    params = %{text: text, media_path: Keyword.get(opts, :media)}
    schedule_step(:tweet_navigate, 0)
    {:reply, :ok, %{state | state: :tweet, step: :navigate, params: params}}
  end

  def handle_call({action, _}, _from, state) when action in [:publish_article, :post_thread],
    do: {:reply, {:error, :busy}, state}

  def handle_call(:status, _from, state),
    do: {:reply, Map.take(state, [:state, :step, :error, :result]), state}

  def handle_call(:abort, _from, state) do
    # Cancel any pending async task -- demonitor and flush to ignore stale results
    if state.task_ref do
      Process.demonitor(state.task_ref, [:flush])
    end
    {:reply, :ok, %{initial_state() | result: state.result}}
  end

  # ── Step Scheduler ──────────────────────────────────────────────────────
  # Instead of Process.sleep blocking the GenServer, we send ourselves a
  # message after the delay. The GenServer remains free to answer :status
  # and :abort between steps.

  defp schedule_step(step, delay_ms) do
    Process.send_after(self(), {:step, step}, delay_ms)
  end

  @impl true
  def handle_info({:step, _step}, %{state: :idle} = state) do
    # Pipeline was aborted; discard stale step message
    {:noreply, state}
  end

  # ── Article Pipeline ────────────────────────────────────────────────────

  def handle_info({:step, :art_navigate}, state) do
    Logger.info("[XPub] Navigating to Articles")
    osascript_set_url("https://x.com/compose/articles")
    schedule_step(:art_create_draft, 4_000)
    {:noreply, %{state | step: :navigate}}
  end

  def handle_info({:step, :art_create_draft}, state) do
    Logger.info("[XPub] Creating draft")
    chrome_js(~s|document.querySelector("[aria-label=create]").click()|)
    schedule_step(:art_create_draft_click, 3_000)
    {:noreply, %{state | step: :create_draft}}
  end

  def handle_info({:step, :art_create_draft_click}, state) do
    chrome_js(~s|var t=document.querySelectorAll("[data-testid=twitter-article-title]");if(t.length>0)t[0].click()|)
    schedule_step(:art_set_title, 3_000)
    {:noreply, state}
  end

  def handle_info({:step, :art_set_title}, state) do
    title = state.params[:title] || state.params["title"] || "Untitled"
    Logger.info("[XPub] Setting title: #{title}")
    chrome_js(~s|var t=document.querySelector("textarea[placeholder=\\"Add a title\\"]");if(t){var s=Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype,"value").set;s.call(t,"#{esc(title)}");t.dispatchEvent(new Event("input",{bubbles:true}))}|)
    schedule_step(:art_paste, 1_000)
    {:noreply, %{state | step: :set_title}}
  end

  def handle_info({:step, :art_paste}, state) do
    html_path = state.params[:html_path] || state.params["html_path"]
    Logger.info("[XPub] Pasting content")

    # Run clipboard copy in a Task so it doesn't block
    task = Task.async(fn ->
      System.cmd("python3", ["/tmp/copy_to_clipboard.py", "html", "--file", html_path])
      :clipboard_done
    end)

    {:noreply, %{state | step: :paste_content, task_ref: task.ref}}
  end

  def handle_info({ref, :clipboard_done}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    schedule_step(:art_paste_focus, 1_000)
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info({:step, :art_paste_focus}, state) do
    chrome_js(~s|var e=document.querySelector("[role=textbox]");if(e){e.focus();e.click()}|)
    schedule_step(:art_paste_key, 500)
    {:noreply, state}
  end

  def handle_info({:step, :art_paste_key}, state) do
    computer_use_key("cmd+v")
    cover = state.params[:cover_image_path] || state.params["cover_image_path"]
    next = if cover, do: :art_cover, else: :art_check_video
    schedule_step(next, 3_000)
    {:noreply, state}
  end

  def handle_info({:step, :art_cover}, state) do
    cover = state.params[:cover_image_path] || state.params["cover_image_path"]
    Logger.info("[XPub] Uploading cover: #{cover}")
    upload_image_datatransfer(cover, ~s|input[type=file][accept*=image]|)
    schedule_step(:art_cover_apply, 3_000)
    {:noreply, %{state | step: :upload_cover}}
  end

  def handle_info({:step, :art_cover_apply}, state) do
    chrome_js(~s|var b=document.querySelectorAll("button");for(var i=0;i<b.length;i++){if(b[i].textContent.trim()==="Apply"){b[i].click();break}}|)
    schedule_step(:art_check_video, 2_000)
    {:noreply, state}
  end

  def handle_info({:step, :art_check_video}, state) do
    video = state.params[:video_path] || state.params["video_path"]
    if video do
      schedule_step(:art_video, 0)
      {:noreply, %{state | step: :upload_video}}
    else
      schedule_step(:art_done, 0)
      {:noreply, %{state | step: :done}}
    end
  end

  def handle_info({:step, :art_video}, state) do
    Logger.info("[XPub] Opening media menu + uploading video")
    chrome_js(~s|var b=document.querySelectorAll("button,[role=button]");for(var i=0;i<b.length;i++){if(b[i].getAttribute("aria-label")==="Add Media"){b[i].click();break}}|)
    schedule_step(:art_video_menu, 2_000)
    {:noreply, %{state | step: :upload_video}}
  end

  def handle_info({:step, :art_video_menu}, state) do
    chrome_js(~s|var m=document.querySelectorAll("[role=menuitem]");for(var i=0;i<m.length;i++){if(m[i].textContent.trim()==="Media"){m[i].click();break}}|)
    schedule_step(:art_video_upload, 2_000)
    {:noreply, state}
  end

  def handle_info({:step, :art_video_upload}, state) do
    # Video upload is slow -- run in a Task
    task = Task.async(fn ->
      System.cmd("python3", ["/tmp/upload_video.py"], cd: "/tmp", stderr_to_stdout: true)
      :video_upload_done
    end)

    {:noreply, %{state | task_ref: task.ref}}
  end

  def handle_info({ref, :video_upload_done}, %{task_ref: ref, state: :article} = state) do
    Process.demonitor(ref, [:flush])
    schedule_step(:art_done, 5_000)
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info({:step, :art_done}, state) do
    Logger.info("[XPub] Article draft complete")
    {:noreply, %{state | state: :idle, step: nil, result: :article_saved}}
  end

  # ── Thread Pipeline ─────────────────────────────────────────────────────

  def handle_info({:step, :thread_navigate}, state) do
    Logger.info("[XPub] Navigating to compose")
    osascript_set_url("https://x.com/compose/post")
    schedule_step(:thread_post, 4_000)
    {:noreply, %{state | step: :navigate}}
  end

  def handle_info({:step, :thread_post}, state) do
    tweets = state.params[:tweets] || state.params["tweets"] || []
    index = state.params[:index] || 0

    if index >= length(tweets) do
      Logger.info("[XPub] Thread complete (#{index} tweets)")
      {:noreply, %{state | state: :idle, step: nil, result: {:thread_done, index}}}
    else
      tweet = Enum.at(tweets, index)
      Logger.info("[XPub] Tweet #{index + 1}/#{length(tweets)}")

      chrome_js(~s|var e=document.querySelector("[data-testid=tweetTextarea_0]");if(e)e.focus()|)
      schedule_step({:thread_type, tweet, index}, 500)
      {:noreply, %{state | step: :"tweet_#{index + 1}"}}
    end
  end

  def handle_info({:step, {:thread_type, tweet, index}}, state) do
    computer_use_type(tweet)
    tweets = state.params[:tweets] || state.params["tweets"] || []

    # Media on first tweet only
    if index == 0 do
      media = state.params[:media_path] || state.params["media_path"]
      if media do
        Logger.info("[XPub] Attaching media to tweet 1")
        schedule_step({:thread_upload_media, media, index}, 1_000)
      else
        schedule_step({:thread_click_post, index}, 1_000)
      end
    else
      schedule_step({:thread_click_post, index}, 1_000)
    end

    {:noreply, state}
  end

  def handle_info({:step, {:thread_upload_media, media, index}}, state) do
    # Video upload is slow -- run in a Task
    task = Task.async(fn ->
      upload_video_chunked(media)
      {:media_upload_done, index}
    end)

    {:noreply, %{state | task_ref: task.ref}}
  end

  def handle_info({ref, {:media_upload_done, index}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    schedule_step({:thread_click_post, index}, 10_000)
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info({:step, {:thread_click_post, index}}, state) do
    chrome_js(~s|var b=document.querySelector("[data-testid=tweetButton]");if(b)b.click()|)
    tweets = state.params[:tweets] || state.params["tweets"] || []

    if index == 0 and length(tweets) > 1 do
      schedule_step({:thread_goto_profile, index}, 5_000)
    else
      new_params = Map.put(state.params, :index, index + 1)
      schedule_step(:thread_post, 3_000)
      {:noreply, %{state | params: new_params}}
    end
    |> case do
      {:noreply, _} = reply -> reply
      _ -> {:noreply, state}
    end
  end

  def handle_info({:step, {:thread_goto_profile, index}}, state) do
    osascript_set_url("https://x.com/StraughterG")
    schedule_step({:thread_click_tweet, index}, 4_000)
    {:noreply, state}
  end

  def handle_info({:step, {:thread_click_tweet, index}}, state) do
    chrome_js(~s|var t=document.querySelector("[data-testid=tweet]");if(t)t.click()|)
    schedule_step({:thread_click_reply, index}, 3_000)
    {:noreply, state}
  end

  def handle_info({:step, {:thread_click_reply, index}}, state) do
    chrome_js(~s|var r=document.querySelector("[data-testid=reply]");if(r)r.click()|)
    new_params = Map.put(state.params, :index, index + 1)
    schedule_step(:thread_post, 2_000)
    {:noreply, %{state | params: new_params}}
  end

  # ── Single Tweet Pipeline ───────────────────────────────────────────────

  def handle_info({:step, :tweet_navigate}, state) do
    osascript_set_url("https://x.com/compose/post")
    schedule_step(:tweet_focus, 4_000)
    {:noreply, %{state | step: :navigate}}
  end

  def handle_info({:step, :tweet_focus}, state) do
    chrome_js(~s|var e=document.querySelector("[data-testid=tweetTextarea_0]");if(e)e.focus()|)
    schedule_step(:tweet_type, 500)
    {:noreply, state}
  end

  def handle_info({:step, :tweet_type}, state) do
    computer_use_type(state.params.text)
    if state.params.media_path do
      schedule_step(:tweet_upload_media, 1_000)
    else
      schedule_step(:tweet_click_post, 1_000)
    end
    {:noreply, %{state | step: :typing}}
  end

  def handle_info({:step, :tweet_upload_media}, state) do
    task = Task.async(fn ->
      upload_video_chunked(state.params.media_path)
      :tweet_media_done
    end)

    {:noreply, %{state | step: :uploading_media, task_ref: task.ref}}
  end

  def handle_info({ref, :tweet_media_done}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    schedule_step(:tweet_click_post, 10_000)
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info({:step, :tweet_click_post}, state) do
    chrome_js(~s|var b=document.querySelector("[data-testid=tweetButton]");if(b)b.click()|)
    schedule_step(:tweet_done, 3_000)
    {:noreply, %{state | step: :posting}}
  end

  def handle_info({:step, :tweet_done}, state) do
    Logger.info("[XPub] Tweet posted")
    {:noreply, %{state | state: :idle, step: nil, result: :tweet_posted}}
  end

  # ── Task Failures ───────────────────────────────────────────────────────
  # If an async Task crashes, we get a :DOWN message. Log and reset.

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.error("[XPub] Async task failed: #{inspect(reason)}")
    {:noreply, %{state | state: :idle, step: nil, error: reason, task_ref: nil}}
  end

  # Catch-all for stale task results after abort
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("[XPub] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp osascript_set_url(url) do
    System.cmd("osascript", ["-e", ~s|tell application "Google Chrome" to set URL of active tab of first window to "#{url}"|])
  end

  defp chrome_js(js) do
    escaped = js |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"") |> String.replace("\n", " ")
    System.cmd("osascript", ["-e", ~s|tell application "Google Chrome" to execute active tab of first window javascript "#{escaped}"|], stderr_to_stdout: true)
  end

  defp computer_use_key(key) do
    json = Jason.encode!(%{arguments: %{action: "key", text: key}})
    System.cmd("curl", ["-s", "-X", "POST", "http://localhost:8089/api/v1/tools/computer_use/execute", "-H", "Content-Type: application/json", "-d", json])
  end

  defp computer_use_type(text) do
    json = Jason.encode!(%{arguments: %{action: "type", text: text}})
    System.cmd("curl", ["-s", "-X", "POST", "http://localhost:8089/api/v1/tools/computer_use/execute", "-H", "Content-Type: application/json", "-d", json])
  end

  defp esc(text), do: text |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"") |> String.replace("\n", "\\n")

  defp upload_image_datatransfer(image_path, selector) do
    {_, 0} = System.cmd("python3", ["-c", """
    from PIL import Image
    img = Image.open("#{image_path}")
    if img.width > 1400: img = img.resize((1400, int(1400 * img.height / img.width)))
    img.convert("RGB").save("/tmp/_upload_img.jpg", quality=80)
    """])

    b64 = File.read!("/tmp/_upload_img.jpg") |> Base.encode64()

    js = """
    (function(){var b64="#{b64}";var c=atob(b64);var b=new Uint8Array(c.length);for(var i=0;i<c.length;i++)b[i]=c.charCodeAt(i);var blob=new Blob([b],{type:"image/jpeg"});var f=new File([blob],"img.jpg",{type:"image/jpeg",lastModified:Date.now()});var dt=new DataTransfer();dt.items.add(f);var inp=document.querySelector("#{selector}");inp.files=dt.files;inp.dispatchEvent(new Event("change",{bubbles:true}));return "ok "+f.size})();
    """

    File.write!("/tmp/_upload.js", js)
    System.cmd("osascript", ["-e", ~s|set js to do shell script "cat /tmp/_upload.js"\ntell application "Google Chrome" to execute active tab of first window javascript js|])
  end

  defp upload_video_chunked(video_path) do
    System.cmd("python3", ["/tmp/upload_video.py"], cd: "/tmp", stderr_to_stdout: true, env: [{"VIDEO_PATH", video_path}])
  end
end
