defmodule Daemon.Production.BrowserPipeline do
  @moduledoc """
  Shared browser automation helpers for multi-platform film production.

  Every function targets a specific Chrome window by its `given name`,
  enabling multiple pipelines (Flow, Sora, Runway, etc.) to run in
  separate windows without interfering with each other.

  All Chrome interaction uses `osascript` AppleScript commands and
  `cliclick` for physical mouse events.
  """

  require Logger

  # ── Navigation ───────────────────────────────────────────────────────

  @doc "Navigate a named Chrome window to a URL."
  @spec navigate(String.t(), String.t()) :: String.t()
  def navigate(window_name, url) do
    osascript([
      ~s(tell application "Google Chrome"),
      ~s(  set targetWindow to first window whose given name is "#{window_name}"),
      ~s(  set URL of active tab of targetWindow to "#{url}"),
      ~s(end tell)
    ])
  end

  @doc "Get the current URL of a named Chrome window."
  @spec get_url(String.t()) :: String.t()
  def get_url(window_name) do
    osascript([
      ~s(tell application "Google Chrome"),
      ~s(  set targetWindow to first window whose given name is "#{window_name}"),
      ~s(  get URL of active tab of targetWindow),
      ~s(end tell)
    ])
  end

  # ── JavaScript Execution ─────────────────────────────────────────────

  @doc "Execute JavaScript in a named Chrome window. Returns the result string."
  @spec execute_js(String.t(), String.t()) :: String.t()
  def execute_js(window_name, js_code) do
    escaped = js_code |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

    osascript([
      ~s(tell application "Google Chrome"),
      ~s(  set targetWindow to first window whose given name is "#{window_name}"),
      ~s(  tell active tab of targetWindow),
      ~s(    execute javascript "#{escaped}"),
      ~s(  end tell),
      ~s(end tell)
    ])
  end

  @doc """
  Execute JavaScript from a file in a named Chrome window.
  Avoids escaping hell for complex JS payloads.
  """
  @spec execute_js_file(String.t(), String.t()) :: String.t()
  def execute_js_file(window_name, file_path) do
    osascript([
      ~s(set jsCode to do shell script "cat #{file_path}"),
      ~s(tell application "Google Chrome"),
      ~s(  set targetWindow to first window whose given name is "#{window_name}"),
      ~s(  tell active tab of targetWindow),
      ~s(    execute javascript jsCode),
      ~s(  end tell),
      ~s(end tell)
    ])
  end

  # ── Window Management ────────────────────────────────────────────────

  @doc """
  Ensure a named Chrome window exists. If no window with the given name
  exists, create one and navigate it to the provided URL.
  Returns `:existing` or `:created`.
  """
  @spec ensure_window(String.t(), String.t()) :: :existing | :created
  def ensure_window(window_name, url) do
    check = osascript([
      ~s(tell application "Google Chrome"),
      ~s(  set matchCount to 0),
      ~s(  repeat with w in windows),
      ~s(    if given name of w is "#{window_name}" then set matchCount to matchCount + 1),
      ~s(  end repeat),
      ~s(  matchCount as text),
      ~s(end tell)
    ])

    case String.trim(check) do
      "0" ->
        osascript([
          ~s(tell application "Google Chrome"),
          ~s(  activate),
          ~s(  set newWin to make new window),
          ~s(  set given name of newWin to "#{window_name}"),
          ~s(  set URL of active tab of newWin to "#{url}"),
          ~s(end tell)
        ])

        Logger.info("[BrowserPipeline] Created window '#{window_name}' → #{url}")
        :created

      _ ->
        Logger.info("[BrowserPipeline] Window '#{window_name}' already exists")
        :existing
    end
  end

  # ── Mouse / Focus ────────────────────────────────────────────────────

  @doc """
  Bring a named Chrome window to the front by setting its index to 1,
  then perform a cliclick at the given screen coordinates.
  """
  @spec focus_and_click(String.t(), integer(), integer()) :: :ok
  def focus_and_click(window_name, x, y) do
    osascript([
      ~s(tell application "Google Chrome"),
      ~s(  set targetWindow to first window whose given name is "#{window_name}"),
      ~s(  set index of targetWindow to 1),
      ~s(end tell)
    ])

    Process.sleep(200)
    System.cmd("cliclick", ["c:#{x},#{y}"])
    :ok
  end

  # ── File Upload ──────────────────────────────────────────────────────

  @doc """
  Upload a file into a named Chrome window via DataTransfer JS injection.
  Targets the first `input[type=file]` on the page.
  """
  @spec upload_file(String.t(), String.t()) :: String.t()
  def upload_file(window_name, file_path) do
    # Build the upload JS via shell to avoid base64 escaping issues
    script = """
    #!/bin/bash
    B64=$(base64 -i "$1" | tr -d '\\n')
    EXT="${1##*.}"
    case "$EXT" in
      jpg|jpeg) MIME="image/jpeg" ;;
      png) MIME="image/png" ;;
      webp) MIME="image/webp" ;;
      mp4) MIME="video/mp4" ;;
      *) MIME="application/octet-stream" ;;
    esac
    FNAME=$(basename "$1")
    cat > /tmp/osa_browser_upload.js << JSEOF
    var b64 = "$B64";
    var binary = atob(b64);
    var arr = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) arr[i] = binary.charCodeAt(i);
    var file = new File([arr], "$FNAME", {type: "$MIME"});
    var dt = new DataTransfer();
    dt.items.add(file);
    var input = document.querySelector("input[type=file]");
    if (input) {
      input.files = dt.files;
      input.dispatchEvent(new Event("change", {bubbles: true}));
      "uploaded " + file.size + " bytes";
    } else {
      "no file input found";
    }
    JSEOF
    """

    File.write!("/tmp/osa_build_browser_upload.sh", script)
    System.cmd("bash", ["/tmp/osa_build_browser_upload.sh", file_path])

    execute_js_file(window_name, "/tmp/osa_browser_upload.js")
  end

  # ── Polling / Waits ──────────────────────────────────────────────────

  @doc """
  Wait for a JavaScript condition to return a truthy value in the named window.
  Polls every `interval_ms` up to `timeout_ms`. Returns `{:ok, result}` or `:timeout`.
  """
  @spec wait_for(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t()} | :timeout
  def wait_for(window_name, js_condition, timeout_ms \\ 90_000, interval_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(window_name, js_condition, deadline, interval_ms)
  end

  defp do_wait_for(window_name, js_condition, deadline, interval_ms) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      :timeout
    else
      result = execute_js(window_name, js_condition)
      trimmed = String.trim(result)

      if truthy?(trimmed) do
        {:ok, trimmed}
      else
        Process.sleep(interval_ms)
        do_wait_for(window_name, js_condition, deadline, interval_ms)
      end
    end
  end

  defp truthy?(""), do: false
  defp truthy?("false"), do: false
  defp truthy?("null"), do: false
  defp truthy?("undefined"), do: false
  defp truthy?("0"), do: false
  defp truthy?("missing value"), do: false
  defp truthy?(_), do: true

  # ── Text Input ───────────────────────────────────────────────────────

  @doc """
  Focus a prompt element (identified by `selector_js` returning a DOM element)
  in the named window, then paste `text` via pbcopy + Cmd+V.
  """
  @spec focus_and_paste(String.t(), String.t(), String.t()) :: :ok
  def focus_and_paste(window_name, selector_js, text) do
    # Focus the element and get its screen coordinates
    focus_js = """
    var el = #{selector_js};
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

    coords = execute_js(window_name, focus_js)

    # Physical click to ensure real focus (add Chrome toolbar offset)
    case String.split(String.trim(coords), ",") do
      [x_str, y_str] ->
        x = String.to_integer(x_str)
        y = String.to_integer(y_str)

        if x > 0 and y > 0 do
          focus_and_click(window_name, x, y + 112)
        end

      _ ->
        :ok
    end

    Process.sleep(300)

    # Write text to file, pbcopy, Cmd+V
    File.write!("/tmp/osa_browser_paste.txt", text)
    System.cmd("bash", ["-c", "cat /tmp/osa_browser_paste.txt | pbcopy"])

    # Bring the named window to front and paste
    osascript([
      ~s(tell application "Google Chrome"),
      ~s(  set targetWindow to first window whose given name is "#{window_name}"),
      ~s(  set index of targetWindow to 1),
      ~s(end tell),
      ~s(delay 0.3),
      ~s(tell application "System Events"),
      ~s(  keystroke "v" using {command down}),
      ~s(end tell)
    ])

    :ok
  end

  # ── osascript Runner (Internal) ──────────────────────────────────────

  @doc false
  def osascript(lines) do
    args = Enum.flat_map(lines, fn line -> ["-e", line] end)

    case System.cmd("osascript", args, stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

      {output, _} ->
        Logger.warning("[BrowserPipeline] osascript error: #{String.trim(output)}")
        String.trim(output)
    end
  end
end
