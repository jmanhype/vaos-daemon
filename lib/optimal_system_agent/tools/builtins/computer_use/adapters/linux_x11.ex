defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.LinuxX11 do
  @moduledoc """
  Computer use adapter for Linux X11 (Xorg) sessions.

  Requires `xdotool` for all input synthesis. Screenshots prefer `maim` and
  fall back to `scrot` when maim is not installed.

  The adapter is available only when all of the following hold:
  - OS is Linux
  - `xdotool` is on `$PATH`

  Key combo parsing converts high-level names (cmd, ctrl, alt, shift) to the
  xdotool/X11 keysym names expected by `xdotool key`.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  require Logger

  @screenshot_dir Path.expand("~/.osa/screenshots")

  # ---------------------------------------------------------------------------
  # xdotool / X11 key name map
  # ---------------------------------------------------------------------------

  @key_map %{
    # Navigation / editing
    "return" => "Return",
    "enter" => "Return",
    "tab" => "Tab",
    "space" => "space",
    "delete" => "BackSpace",
    "backspace" => "BackSpace",
    "escape" => "Escape",
    "esc" => "Escape",
    # Arrow keys
    "left" => "Left",
    "right" => "Right",
    "up" => "Up",
    "down" => "Down",
    # Extended navigation
    "home" => "Home",
    "end" => "End",
    "pageup" => "Prior",
    "pagedown" => "Next",
    # Function keys
    "f1" => "F1",
    "f2" => "F2",
    "f3" => "F3",
    "f4" => "F4",
    "f5" => "F5",
    "f6" => "F6",
    "f7" => "F7",
    "f8" => "F8",
    "f9" => "F9",
    "f10" => "F10",
    "f11" => "F11",
    "f12" => "F12",
    # Modifiers — Linux maps Cmd/Command to the Super key
    "cmd" => "super",
    "command" => "super",
    "ctrl" => "ctrl",
    "control" => "ctrl",
    "alt" => "alt",
    "option" => "alt",
    "shift" => "shift"
  }

  # ---------------------------------------------------------------------------
  # Behaviour: platform / availability
  # ---------------------------------------------------------------------------

  @impl true
  def platform, do: :linux_x11

  @impl true
  def available? do
    :os.type() == {:unix, :linux} and
      System.find_executable("xdotool") != nil
  end

  # ---------------------------------------------------------------------------
  # Behaviour: screenshot
  # ---------------------------------------------------------------------------

  @impl true
  def screenshot(opts) do
    screenshot_dir = ensure_screenshot_dir()
    timestamp = System.system_time(:millisecond)
    path = Path.join(screenshot_dir, "screenshot_#{timestamp}.png")

    region = Map.get(opts, "region")

    result =
      cond do
        System.find_executable("maim") != nil ->
          take_screenshot_maim(path, region)

        System.find_executable("scrot") != nil ->
          take_screenshot_scrot(path, region)

        true ->
          {:error, "No screenshot tool found. Install maim or scrot (apt install maim)."}
      end

    case result do
      {:ok, _} -> {:ok, "Screenshot saved to #{path}. Use file_read to view it."}
      error -> error
    end
  end

  defp take_screenshot_maim(path, nil) do
    run_cmd("maim", [path])
  end

  defp take_screenshot_maim(path, %{"x" => x, "y" => y, "width" => w, "height" => h}) do
    run_cmd("maim", ["--geometry", "#{w}x#{h}+#{x}+#{y}", path])
  end

  defp take_screenshot_scrot(path, nil) do
    run_cmd("scrot", [path])
  end

  defp take_screenshot_scrot(path, %{"x" => x, "y" => y, "width" => w, "height" => h}) do
    run_cmd("scrot", ["-a", "#{x},#{y},#{w},#{h}", path])
  end

  # ---------------------------------------------------------------------------
  # Behaviour: mouse actions
  # ---------------------------------------------------------------------------

  @impl true
  def click(x, y, opts) do
    button = Map.get(opts, "button", 1) |> to_string()

    case run_cmd("xdotool", ["mousemove", "#{x}", "#{y}", "click", button]) do
      {:ok, _} -> {:ok, "Clicked at (#{x}, #{y}) with button #{button}."}
      error -> error
    end
  end

  @impl true
  def double_click(x, y) do
    case run_cmd("xdotool", ["mousemove", "#{x}", "#{y}", "click", "--repeat", "2", "1"]) do
      {:ok, _} -> {:ok, "Double-clicked at (#{x}, #{y})."}
      error -> error
    end
  end

  @impl true
  def move_mouse(x, y) do
    case run_cmd("xdotool", ["mousemove", "#{x}", "#{y}"]) do
      {:ok, _} -> {:ok, "Mouse moved to (#{x}, #{y})."}
      error -> error
    end
  end

  @impl true
  def drag(start_x, start_y, end_x, end_y) do
    args = [
      "mousemove", "#{start_x}", "#{start_y}",
      "mousedown", "1",
      "mousemove", "#{end_x}", "#{end_y}",
      "mouseup", "1"
    ]

    case run_cmd("xdotool", args) do
      {:ok, _} -> {:ok, "Dragged from (#{start_x}, #{start_y}) to (#{end_x}, #{end_y})."}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: keyboard actions
  # ---------------------------------------------------------------------------

  @impl true
  def type_text(text) do
    case run_cmd("xdotool", ["type", "--clearmodifiers", text]) do
      {:ok, _} -> {:ok, "Typed text successfully."}
      error -> error
    end
  end

  @impl true
  def key_press(combo) do
    xdotool_combo = parse_key_combo(combo)

    case run_cmd("xdotool", ["key", xdotool_combo]) do
      {:ok, _} -> {:ok, "Key combo '#{combo}' sent (xdotool: '#{xdotool_combo}')."}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: scroll
  # ---------------------------------------------------------------------------

  @impl true
  def scroll(direction, amount) do
    button = scroll_button(direction)

    case run_cmd("xdotool", ["click", "--repeat", "#{amount}", "#{button}"]) do
      {:ok, _} -> {:ok, "Scrolled #{direction} by #{amount} units."}
      error -> error
    end
  end

  # xdotool scroll buttons: 4=up, 5=down, 6=left, 7=right
  defp scroll_button("up"), do: 4
  defp scroll_button("down"), do: 5
  defp scroll_button("left"), do: 6
  defp scroll_button("right"), do: 7
  defp scroll_button(other), do: raise(ArgumentError, "Unknown scroll direction: #{other}")

  # ---------------------------------------------------------------------------
  # Behaviour: accessibility tree
  # ---------------------------------------------------------------------------

  @impl true
  def get_accessibility_tree(_opts) do
    {:error, "Accessibility tree not yet implemented for Linux X11. Use screenshot fallback."}
  end

  # ---------------------------------------------------------------------------
  # Key combo parsing
  # ---------------------------------------------------------------------------

  @doc """
  Convert a human-readable key combo like `"cmd+shift+c"` to the xdotool
  keysym format `"super+shift+c"`.

  Each token separated by `+` is looked up in `@key_map`. Tokens not found in
  the map (e.g. ordinary alphanumeric keys) are passed through unchanged.
  """
  @spec parse_key_combo(String.t()) :: String.t()
  def parse_key_combo(combo) do
    combo
    |> String.downcase()
    |> String.split("+", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn token -> Map.get(@key_map, token, token) end)
    |> Enum.join("+")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp ensure_screenshot_dir do
    try do
      File.mkdir_p!(@screenshot_dir)
      @screenshot_dir
    rescue
      _ ->
        fallback = Path.join(System.tmp_dir!(), "osa_screenshots")
        File.mkdir_p!(fallback)
        fallback
    end
  end

  defp run_cmd(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, "ok"}

      {output, code} ->
        trimmed = String.trim(output)
        Logger.warning("#{executable} exited #{code}: #{trimmed}")
        {:error, "#{executable} failed (exit #{code}): #{trimmed}"}
    end
  rescue
    e ->
      Logger.error("#{executable} raised: #{Exception.message(e)}")
      {:error, "#{executable} raised: #{Exception.message(e)}"}
  end
end
