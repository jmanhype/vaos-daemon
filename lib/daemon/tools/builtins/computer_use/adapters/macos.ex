defmodule Daemon.Tools.Builtins.ComputerUse.Adapters.MacOS do
  @moduledoc """
  macOS adapter for the ComputerUse tool.

  Uses native macOS APIs: `screencapture` for screenshots, osascript/AppleScript
  with Python/Quartz bindings for mouse and keyboard events. No external
  dependencies beyond what ships with macOS.

  Requires Accessibility API permission when dispatching input events. The user
  must grant access under System Settings → Privacy & Security → Accessibility.
  """

  @behaviour Daemon.Tools.Builtins.ComputerUse.Adapter

  require Logger

  @screenshot_dir Path.expand("~/.daemon/screenshots")

  # ---------------------------------------------------------------------------
  # Behaviour callbacks — identity / guard
  # ---------------------------------------------------------------------------

  @impl true
  def platform, do: :macos

  @impl true
  def available?, do: :os.type() == {:unix, :darwin}

  # ---------------------------------------------------------------------------
  # Behaviour callbacks — screenshot
  # ---------------------------------------------------------------------------

  @impl true
  def screenshot(opts) do
    screenshot_dir =
      try do
        File.mkdir_p!(@screenshot_dir)
        @screenshot_dir
      rescue
        _ ->
          fallback = Path.join(System.tmp_dir!(), "osa_screenshots")
          File.mkdir_p!(fallback)
          fallback
      end

    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    path = Path.join(screenshot_dir, "screenshot_#{timestamp}.png")

    cmd_args =
      case Map.get(opts, "region") do
        %{"x" => x, "y" => y, "width" => w, "height" => h} ->
          ["-x", "-R", "#{x},#{y},#{w},#{h}", path]

        _ ->
          ["-x", path]
      end

    case System.cmd("screencapture", cmd_args, stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, "Screenshot saved to #{path}. Use file_read to view it."}

      {output, code} ->
        {:error, "screencapture failed (exit #{code}): #{String.trim(output)}"}
    end
  rescue
    e -> {:error, "Screenshot failed: #{Exception.message(e)}"}
  end

  # ---------------------------------------------------------------------------
  # Behaviour callbacks — mouse
  # ---------------------------------------------------------------------------

  @impl true
  def click(x, y, _opts), do: applescript_click(x, y, 1)

  @impl true
  def double_click(x, y), do: applescript_click(x, y, 2)

  @impl true
  def move_mouse(x, y) do
    script = """
    do shell script "
    /usr/bin/python3 -c '
    import Quartz
    event = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, (#{x}, #{y}), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
    '
    "
    """

    run_osascript(String.trim(script), "move_mouse")
  end

  @impl true
  def drag(start_x, start_y, end_x, end_y) do
    script = """
    do shell script "
    /usr/bin/python3 -c '
    import Quartz, time
    # Mouse down at start
    e1 = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseDown, (#{start_x}, #{start_y}), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e1)
    time.sleep(0.05)
    # Drag to end
    e2 = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseDragged, (#{end_x}, #{end_y}), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e2)
    time.sleep(0.05)
    # Mouse up at end
    e3 = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseUp, (#{end_x}, #{end_y}), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e3)
    '
    "
    """

    run_osascript(String.trim(script), "drag")
  end

  @impl true
  def scroll(direction, amount) do
    {dx, dy} =
      case direction do
        "up" -> {0, amount}
        "down" -> {0, -amount}
        "left" -> {amount, 0}
        "right" -> {-amount, 0}
      end

    script = """
    do shell script "
    /usr/bin/python3 -c '
    import Quartz
    event = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitLine, 2, #{dy}, #{dx})
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
    '
    "
    """

    run_osascript(String.trim(script), "scroll")
  end

  # ---------------------------------------------------------------------------
  # Behaviour callbacks — keyboard
  # ---------------------------------------------------------------------------

  @impl true
  def type_text(text) do
    escaped = sanitize_for_applescript(text)
    script = ~s(tell application "System Events" to keystroke "#{escaped}")
    run_osascript(script, "type")
  end

  @impl true
  def key_press(combo) do
    {modifiers, key} = parse_key_combo(combo)

    script =
      if modifiers == [] do
        key_code = key_name_to_code(key)

        if key_code do
          ~s(tell application "System Events" to key code #{key_code})
        else
          ~s(tell application "System Events" to keystroke "#{sanitize_for_applescript(key)}")
        end
      else
        modifier_clause = Enum.map_join(modifiers, ", ", &applescript_modifier/1)
        key_code = key_name_to_code(key)

        if key_code do
          ~s(tell application "System Events" to key code #{key_code} using {#{modifier_clause}})
        else
          ~s(tell application "System Events" to keystroke "#{sanitize_for_applescript(key)}" using {#{modifier_clause}})
        end
      end

    run_osascript(script, "key")
  end

  # ---------------------------------------------------------------------------
  # Behaviour callbacks — accessibility (optional)
  # ---------------------------------------------------------------------------

  @impl true
  def get_accessibility_tree(_opts) do
    # AXorcist integration is planned for a future release. Until then, callers
    # should fall back to screenshot-based inspection.
    {:error, "Accessibility tree not yet implemented for macOS. Use screenshot fallback."}
  end

  # ---------------------------------------------------------------------------
  # Private helpers — mouse
  # ---------------------------------------------------------------------------

  defp applescript_click(x, y, count) do
    click_type = if count == 2, do: "2", else: "1"

    script = """
    do shell script "
    /usr/bin/python3 -c '
    import Quartz, time
    point = (#{x}, #{y})
    for i in range(#{click_type}):
        down = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseDown, point, Quartz.kCGMouseButtonLeft)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)
        time.sleep(0.01)
        up = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseUp, point, Quartz.kCGMouseButtonLeft)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)
        if i < #{click_type} - 1: time.sleep(0.05)
    '
    "
    """

    action_name = if count == 2, do: "double_click", else: "click"
    run_osascript(String.trim(script), action_name)
  end

  # ---------------------------------------------------------------------------
  # Private helpers — AppleScript
  # ---------------------------------------------------------------------------

  defp run_osascript(script, action_name) do
    case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, "#{action_name} action completed successfully."}

      {output, code} ->
        {:error, "#{action_name} failed (osascript exit #{code}): #{String.trim(output)}"}
    end
  rescue
    e -> {:error, "#{action_name} failed: #{Exception.message(e)}"}
  end

  # ---------------------------------------------------------------------------
  # Private helpers — keyboard
  # ---------------------------------------------------------------------------

  # Escape backslashes and double quotes so the string is safe inside an
  # AppleScript double-quoted string literal.
  @doc false
  def sanitize_for_applescript(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  # Parse "cmd+shift+c" into {["cmd", "shift"], "c"}.
  # Handles edge cases: modifier-only combos, multi-token keys.
  @doc false
  def parse_key_combo(combo) do
    parts =
      combo
      |> String.downcase()
      |> String.split("+", trim: true)
      |> Enum.map(&String.trim/1)

    modifier_names = ~w(cmd command ctrl control alt option shift fn)

    case Enum.split_with(parts, fn p -> p in modifier_names end) do
      {mods, [key]} -> {mods, key}
      # All tokens were modifiers — treat the last one as the key.
      {mods, []} when mods != [] -> {Enum.drop(mods, -1), List.last(mods)}
      {[], keys} -> {[], Enum.join(keys, "+")}
      {mods, keys} -> {mods, Enum.join(keys, "+")}
    end
  end

  defp applescript_modifier("cmd"), do: "command down"
  defp applescript_modifier("command"), do: "command down"
  defp applescript_modifier("ctrl"), do: "control down"
  defp applescript_modifier("control"), do: "control down"
  defp applescript_modifier("alt"), do: "option down"
  defp applescript_modifier("option"), do: "option down"
  defp applescript_modifier("shift"), do: "shift down"
  defp applescript_modifier("fn"), do: "function down"
  defp applescript_modifier(other), do: "#{other} down"

  # ---------------------------------------------------------------------------
  # Private helpers — key codes
  # ---------------------------------------------------------------------------

  # macOS virtual key codes for named keys.
  # Alphanumeric keys are sent via `keystroke` rather than `key code`.
  @key_codes %{
    "return" => 36,
    "enter" => 36,
    "tab" => 48,
    "space" => 49,
    "delete" => 51,
    "backspace" => 51,
    "escape" => 53,
    "esc" => 53,
    "left" => 123,
    "right" => 124,
    "down" => 125,
    "up" => 126,
    "f1" => 122,
    "f2" => 120,
    "f3" => 99,
    "f4" => 118,
    "f5" => 96,
    "f6" => 97,
    "f7" => 98,
    "f8" => 100,
    "f9" => 101,
    "f10" => 109,
    "f11" => 103,
    "f12" => 111,
    "home" => 115,
    "end" => 119,
    "pageup" => 116,
    "pagedown" => 121,
    "forwarddelete" => 117
  }

  defp key_name_to_code(key), do: Map.get(@key_codes, String.downcase(key))
end
