defmodule Daemon.Production.AiStudioPipeline do
  @moduledoc """
  Browser automation pipeline for Google AI Studio (aistudio.google.com).

  Unlike video pipelines (Film, Kling, Sora), this is a conversational interface —
  no render/poll cycle. The GenServer stays in `:ready` state and accepts
  commands to read the page, send prompts, and extract responses.

  Uses BrowserPipeline with a named Chrome window "AIStudio".

  ## Usage

      AiStudioPipeline.connect()
      AiStudioPipeline.read_page()
      AiStudioPipeline.send_prompt("Explain this code")
      AiStudioPipeline.get_response()
  """
  use GenServer

  require Logger

  alias Daemon.Production.BrowserPipeline

  @window_name "AIStudio"
  @aistudio_url "https://aistudio.google.com"
  @post_navigate_ms 4_000
  @post_paste_ms 1_500

  # ── JS Selectors ──────────────────────────────────────────────────────

  # Find the prompt textarea / contenteditable
  @prompt_selector_js ~S"""
  document.querySelector('.ql-editor[contenteditable="true"]') || document.querySelector('textarea[aria-label*="prompt" i]') || document.querySelector('textarea[placeholder*="Type something" i]') || document.querySelector('[contenteditable="true"][role="textbox"]') || document.querySelector('textarea') || document.querySelector('[contenteditable="true"]')
  """

  # Click the Run / Send button
  @click_run_js ~S"""
  var btns=document.querySelectorAll('button');var found=false;for(var i=0;i<btns.length;i++){var t=btns[i].textContent.trim().toLowerCase();var aria=(btns[i].getAttribute('aria-label')||'').toLowerCase();if(t==='run'||t==='send'||aria==='run'||aria==='send message'||btns[i].querySelector('mat-icon[fonticon="play_arrow"]')||btns[i].querySelector('mat-icon[fonticon="send"]')){btns[i].click();found=true;break;}}found?'run_clicked':'run_not_found'
  """

  # Extract visible page text
  @get_page_text_js ~S"""
  (function(){var main=document.querySelector('main')||document.querySelector('[role="main"]')||document.body;return main.innerText.substring(0,15000);})()
  """

  # Extract the latest model response
  @get_response_js ~S"""
  (function(){var responses=document.querySelectorAll('.response-container, .model-response-text, [data-test-id="model-response"], .markdown-container, ms-text-chunk, .response-content');if(responses.length>0){return responses[responses.length-1].innerText.substring(0,10000);}var turns=document.querySelectorAll('.turn-content, .chat-turn, [class*="response"]');if(turns.length>0){return turns[turns.length-1].innerText.substring(0,10000);}return 'no_response_found';})()
  """

  # Check if model is currently generating
  @is_generating_js ~S"""
  (function(){var spinners=document.querySelectorAll('.loading, .generating, [class*="spinner"], mat-spinner, mat-progress-bar, [aria-label*="loading" i]');for(var i=0;i<spinners.length;i++){var s=window.getComputedStyle(spinners[i]);if(s.display!=='none'&&s.visibility!=='hidden')return 'true';}var stop=document.querySelectorAll('button');for(var i=0;i<stop.length;i++){if(stop[i].textContent.trim().toLowerCase()==='stop')return 'true';}return 'false';})()
  """

  # ── Public API ────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Ensure the AI Studio window exists and is ready."
  @spec connect() :: {:ok, :existing | :created} | {:error, term()}
  def connect, do: GenServer.call(__MODULE__, :connect, 15_000)

  @doc "Read all visible text from the current AI Studio page."
  @spec read_page() :: {:ok, String.t()} | {:error, term()}
  def read_page, do: GenServer.call(__MODULE__, :read_page, 15_000)

  @doc "Paste a prompt into AI Studio and click Run."
  @spec send_prompt(String.t()) :: :ok | {:error, term()}
  def send_prompt(text), do: GenServer.call(__MODULE__, {:send_prompt, text}, 30_000)

  @doc "Extract the latest model response."
  @spec get_response() :: {:ok, String.t()} | {:error, term()}
  def get_response, do: GenServer.call(__MODULE__, :get_response, 15_000)

  @doc "Wait for generation to complete, then return the response."
  @spec get_response_blocking(non_neg_integer()) :: {:ok, String.t()} | :timeout
  def get_response_blocking(timeout_ms \\ 120_000) do
    GenServer.call(__MODULE__, {:get_response_blocking, timeout_ms}, timeout_ms + 5_000)
  end

  @doc "Get the current URL of the AI Studio window."
  @spec get_url() :: {:ok, String.t()} | {:error, term()}
  def get_url, do: GenServer.call(__MODULE__, :get_url, 10_000)

  @doc "Execute arbitrary JavaScript in the AI Studio window."
  @spec evaluate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def evaluate(js), do: GenServer.call(__MODULE__, {:evaluate, js}, 15_000)

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  # ── GenServer Callbacks ───────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{state: :idle, connected_at: nil, last_action: nil}}

  @impl true
  def handle_call(:connect, _from, state) do
    # First, try to find an existing Chrome window/tab already on aistudio.google.com
    # and claim it by renaming to our window name
    result = claim_existing_tab() || BrowserPipeline.ensure_window(@window_name, @aistudio_url)

    if result == :created do
      Process.sleep(@post_navigate_ms)
    end

    Logger.info("[AiStudioPipeline] Connected: #{result}")

    {:reply, {:ok, result},
     %{state | state: :ready, connected_at: DateTime.utc_now(), last_action: :connect}}
  end

  # Scan all Chrome windows for a tab already on aistudio.google.com.
  # If found, rename that window to @window_name so BrowserPipeline can target it.
  defp claim_existing_tab do
    # AppleScript: find window with aistudio tab, rename it
    result =
      BrowserPipeline.osascript([
        ~s(tell application "Google Chrome"),
        ~s(  repeat with w in windows),
        ~s(    repeat with t in tabs of w),
        ~s(      if URL of t contains "aistudio.google.com" then),
        ~s(        set active tab index of w to index of t),
        ~s(        set given name of w to "#{@window_name}"),
        ~s(        return "claimed"),
        ~s(      end if),
        ~s(    end repeat),
        ~s(  end repeat),
        ~s(  return "not_found"),
        ~s(end tell)
      ])

    case String.trim(result) do
      "claimed" ->
        Logger.info("[AiStudioPipeline] Claimed existing AI Studio tab")
        :existing

      _ ->
        nil
    end
  end

  def handle_call(:read_page, _from, %{state: :idle} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:read_page, _from, state) do
    text = BrowserPipeline.execute_js(@window_name, @get_page_text_js)
    {:reply, {:ok, String.trim(text)}, %{state | last_action: :read_page}}
  end

  def handle_call({:send_prompt, text}, _from, %{state: :idle} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:send_prompt, text}, _from, state) do
    # Paste prompt into the input
    BrowserPipeline.focus_and_paste(@window_name, @prompt_selector_js, text)
    Process.sleep(@post_paste_ms)

    # Click Run
    result = BrowserPipeline.execute_js(@window_name, @click_run_js)
    Logger.info("[AiStudioPipeline] Prompt sent, run button: #{result}")

    {:reply, :ok, %{state | last_action: {:send_prompt, result}}}
  end

  def handle_call(:get_response, _from, %{state: :idle} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:get_response, _from, state) do
    text = BrowserPipeline.execute_js(@window_name, @get_response_js)
    {:reply, {:ok, String.trim(text)}, %{state | last_action: :get_response}}
  end

  def handle_call({:get_response_blocking, timeout_ms}, _from, %{state: :idle} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:get_response_blocking, timeout_ms}, _from, state) do
    # Wait for generation to finish
    case BrowserPipeline.wait_for(
           @window_name,
           "(#{@is_generating_js})==='false'?'done':'false'",
           timeout_ms,
           2_000
         ) do
      {:ok, _} ->
        Process.sleep(500)
        text = BrowserPipeline.execute_js(@window_name, @get_response_js)
        {:reply, {:ok, String.trim(text)}, %{state | last_action: :get_response_blocking}}

      :timeout ->
        {:reply, :timeout, %{state | last_action: :get_response_timeout}}
    end
  end

  def handle_call({:evaluate, js}, _from, %{state: :idle} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:evaluate, js}, _from, state) do
    result = BrowserPipeline.execute_js(@window_name, js)
    {:reply, {:ok, String.trim(result)}, %{state | last_action: :evaluate}}
  end

  def handle_call(:get_url, _from, %{state: :idle} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:get_url, _from, state) do
    url = BrowserPipeline.get_url(@window_name)
    {:reply, {:ok, String.trim(url)}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, Map.put(state, :window_name, @window_name), state}
  end
end
