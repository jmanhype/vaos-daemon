defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.LinuxWayland do
  @moduledoc """
  Computer use adapter for Linux Wayland sessions.

  Requires `ydotool` for all input synthesis (ydotool v1+ with Linux input
  event key names). Screenshots prefer `grim` and fall back to
  `gnome-screenshot` when grim is not installed.

  The adapter is available only when all of the following hold:
  - OS is Linux
  - `WAYLAND_DISPLAY` is set **or** `XDG_SESSION_TYPE=wayland`
  - `ydotool` is on `$PATH` (and `ydotoold` daemon is running)

  ydotool uses Linux input event key names (`KEY_ENTER`, `KEY_LEFTCTRL`, etc.)
  rather than X11 keysyms. Modifier and named-key tokens in combo strings are
  mapped accordingly via `@key_map`.

  ## ydotool click codes

  ydotool encodes mouse button + direction in a single byte:
  - Bit 7..4: button index (0 = left, 1 = right, 2 = middle)
  - Bit 3..0: `0x4` = down, `0x8` = up, `0xC` = click (down+up)

  Left click (button 0, down+up) = `0x0C` → hex literal `0xC0`.
  Right click (button 1, down+up) = `0x1C` → but ydotool uses the button
  index in the high nibble, so left=`0xC0`, right=`0xC1`.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  require Logger

  @screenshot_dir Path.expand("~/.osa/screenshots")

  # ydotool left-click button code (button 0, press+release = 0xC0)
  @left_click_code "0xC0"
  # ydotool right-click button code
  @right_click_code "0xC1"

  # ---------------------------------------------------------------------------
  # ydotool Linux input event key name map
  # ---------------------------------------------------------------------------

  @key_map %{
    # Navigation / editing
    "return" => "KEY_ENTER",
    "enter" => "KEY_ENTER",
    "tab" => "KEY_TAB",
    "space" => "KEY_SPACE",
    "delete" => "KEY_BACKSPACE",
    "backspace" => "KEY_BACKSPACE",
    "escape" => "KEY_ESC",
    "esc" => "KEY_ESC",
    # Arrow keys
    "left" => "KEY_LEFT",
    "right" => "KEY_RIGHT",
    "up" => "KEY_UP",
    "down" => "KEY_DOWN",
    # Extended navigation
    "home" => "KEY_HOME",
    "end" => "KEY_END",
    "pageup" => "KEY_PAGEUP",
    "pagedown" => "KEY_PAGEDOWN",
    # Function keys
    "f1" => "KEY_F1",
    "f2" => "KEY_F2",
    "f3" => "KEY_F3",
    "f4" => "KEY_F4",
    "f5" => "KEY_F5",
    "f6" => "KEY_F6",
    "f7" => "KEY_F7",
    "f8" => "KEY_F8",
    "f9" => "KEY_F9",
    "f10" => "KEY_F10",
    "f11" => "KEY_F11",
    "f12" => "KEY_F12",
    # Modifiers
    "cmd" => "KEY_LEFTMETA",
    "command" => "KEY_LEFTMETA",
    "ctrl" => "KEY_LEFTCTRL",
    "control" => "KEY_LEFTCTRL",
    "alt" => "KEY_LEFTALT",
    "option" => "KEY_LEFTALT",
    "shift" => "KEY_LEFTSHIFT"
  }

  # ---------------------------------------------------------------------------
  # Behaviour: platform / availability
  # ---------------------------------------------------------------------------

  @impl true
  def platform, do: :linux_wayland

  @impl true
  def available? do
    is_linux = :os.type() == {:unix, :linux}
    has_ydotool = System.find_executable("ydotool") != nil

    is_wayland =
      System.get_env("WAYLAND_DISPLAY") not in [nil, ""] or
        System.get_env("XDG_SESSION_TYPE") == "wayland"

    is_linux and is_wayland and has_ydotool
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
        System.find_executable("grim") != nil ->
          take_screenshot_grim(path, region)

        System.find_executable("gnome-screenshot") != nil ->
          take_screenshot_gnome(path, region)

        true ->
          {:error,
           "No screenshot tool found. Install grim (apt install grim) or gnome-screenshot."}
      end

    case result do
      {:ok, _} -> {:ok, "Screenshot saved to #{path}. Use file_read to view it."}
      error -> error
    end
  end

  defp take_screenshot_grim(path, nil) do
    run_cmd("grim", [path])
  end

  defp take_screenshot_grim(path, %{"x" => x, "y" => y, "width" => w, "height" => h}) do
    # grim geometry format: "x,y WxH"
    run_cmd("grim", ["-g", "#{x},#{y} #{w}x#{h}", path])
  end

  defp take_screenshot_gnome(path, _region) do
    # gnome-screenshot does not support reliable region capture from CLI;
    # capture full screen and note the limitation.
    case run_cmd("gnome-screenshot", ["-f", path]) do
      {:ok, _} ->
        {:ok, "ok (gnome-screenshot does not support region capture — full screen saved)"}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: mouse actions
  # ---------------------------------------------------------------------------

  @impl true
  def click(x, y, opts) do
    button_code =
      case Map.get(opts, "button", 1) do
        2 -> @right_click_code
        _ -> @left_click_code
      end

    with {:ok, _} <- run_cmd("ydotool", ["mousemove", "-a", "-x", "#{x}", "-y", "#{y}"]),
         {:ok, _} <- run_cmd("ydotool", ["click", button_code]) do
      {:ok, "Clicked at (#{x}, #{y})."}
    end
  end

  @impl true
  def double_click(x, y) do
    with {:ok, _} <- run_cmd("ydotool", ["mousemove", "-a", "-x", "#{x}", "-y", "#{y}"]),
         {:ok, _} <- run_cmd("ydotool", ["click", @left_click_code]),
         {:ok, _} <- run_cmd("ydotool", ["click", @left_click_code]) do
      {:ok, "Double-clicked at (#{x}, #{y})."}
    end
  end

  @impl true
  def move_mouse(x, y) do
    case run_cmd("ydotool", ["mousemove", "-a", "-x", "#{x}", "-y", "#{y}"]) do
      {:ok, _} -> {:ok, "Mouse moved to (#{x}, #{y})."}
      error -> error
    end
  end

  @impl true
  def drag(start_x, start_y, end_x, end_y) do
    # ydotool does not have a single drag command; synthesise mousedown / move / mouseup.
    # Button down = 0x40 (button 0, press only), button up = 0x80 (button 0, release only).
    with {:ok, _} <-
           run_cmd("ydotool", ["mousemove", "-a", "-x", "#{start_x}", "-y", "#{start_y}"]),
         {:ok, _} <- run_cmd("ydotool", ["click", "0x40"]),
         {:ok, _} <-
           run_cmd("ydotool", ["mousemove", "-a", "-x", "#{end_x}", "-y", "#{end_y}"]),
         {:ok, _} <- run_cmd("ydotool", ["click", "0x80"]) do
      {:ok, "Dragged from (#{start_x}, #{start_y}) to (#{end_x}, #{end_y})."}
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: keyboard actions
  # ---------------------------------------------------------------------------

  @impl true
  def type_text(text) do
    case run_cmd("ydotool", ["type", text]) do
      {:ok, _} -> {:ok, "Typed text successfully."}
      error -> error
    end
  end

  @impl true
  def key_press(combo) do
    key_args = parse_key_combo(combo)

    case run_cmd("ydotool", ["key" | key_args]) do
      {:ok, _} -> {:ok, "Key combo '#{combo}' sent (ydotool keys: #{Enum.join(key_args, " ")})."}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: scroll
  # ---------------------------------------------------------------------------

  @impl true
  def scroll(direction, amount) do
    # ydotool mousemove -w moves the wheel. Positive Y = scroll up, negative = down.
    # X axis: positive = left, negative = right (following conventional wheel axes).
    {wheel_x, wheel_y} = scroll_delta(direction, amount)

    x_args = if wheel_x != 0, do: ["-x", "#{wheel_x}"], else: []
    y_args = if wheel_y != 0, do: ["-y", "#{wheel_y}"], else: []
    args = ["mousemove", "-w", "--"] ++ x_args ++ y_args

    case run_cmd("ydotool", args) do
      {:ok, _} -> {:ok, "Scrolled #{direction} by #{amount} units."}
      error -> error
    end
  end

  # Returns {wheel_x, wheel_y} deltas for ydotool mousemove -w
  defp scroll_delta("up", amount), do: {0, amount}
  defp scroll_delta("down", amount), do: {0, -amount}
  defp scroll_delta("left", amount), do: {amount, 0}
  defp scroll_delta("right", amount), do: {-amount, 0}
  defp scroll_delta(other, _), do: raise(ArgumentError, "Unknown scroll direction: #{other}")

  # ---------------------------------------------------------------------------
  # Behaviour: accessibility tree
  # ---------------------------------------------------------------------------

  @impl true
  def get_accessibility_tree(_opts) do
    {:error,
     "Accessibility tree not yet implemented for Linux Wayland. Use screenshot fallback."}
  end

  # ---------------------------------------------------------------------------
  # Key combo parsing
  # ---------------------------------------------------------------------------

  @doc """
  Convert a human-readable combo like `"cmd+shift+c"` to a list of ydotool
  `key` arguments.

  ydotool v1+ accepts Linux input event names directly:
  `ydotool key KEY_LEFTMETA KEY_LEFTSHIFT c`

  Each token in the combo is looked up in `@key_map`. Tokens not found in the
  map are passed through as-is (e.g. plain alphanumeric characters).
  """
  @spec parse_key_combo(String.t()) :: [String.t()]
  def parse_key_combo(combo) do
    combo
    |> String.downcase()
    |> String.split("+", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn token -> Map.get(@key_map, token, token) end)
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
