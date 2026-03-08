defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse do
  @moduledoc """
  Computer use tool — take screenshots, click, type, scroll, and drag on macOS.

  Uses native macOS APIs (screencapture, osascript/AppleScript) with no external
  dependencies. Falls back gracefully when optional tools like `cliclick` are
  available.

  Safety: `:write_destructive` — every action except screenshot requires user
  confirmation via the permission system.

  Gated by the `:computer_use_enabled` application config flag (default `false`).
  """

  @behaviour MiosaTools.Behaviour

  require Logger

  @valid_actions ~w(screenshot click double_click type key scroll move_mouse drag)
  @valid_directions ~w(up down left right)

  # Maximum text length to prevent abuse
  @max_text_length 4096

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def name, do: "computer_use"

  @impl true
  def description do
    "Control the computer — take screenshots, click at coordinates, type text, " <>
      "press keys, scroll. For GUI automation and visual verification."
  end

  @impl true
  def safety, do: :write_destructive

  @impl true
  def available? do
    Application.get_env(:optimal_system_agent, :computer_use_enabled, false) == true
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => @valid_actions,
          "description" => "Action to perform: screenshot, click, double_click, type, key, scroll, move_mouse, drag"
        },
        "x" => %{
          "type" => "integer",
          "description" => "X coordinate for click/move/drag actions"
        },
        "y" => %{
          "type" => "integer",
          "description" => "Y coordinate for click/move/drag actions"
        },
        "text" => %{
          "type" => "string",
          "description" => "Text to type (for type action) or key combo (for key action, e.g. \"cmd+c\", \"enter\", \"tab\")"
        },
        "direction" => %{
          "type" => "string",
          "enum" => @valid_directions,
          "description" => "Scroll direction: up, down, left, right"
        },
        "amount" => %{
          "type" => "integer",
          "description" => "Scroll amount in pixels (default 3 scroll units)"
        },
        "region" => %{
          "type" => "object",
          "properties" => %{
            "x" => %{"type" => "integer"},
            "y" => %{"type" => "integer"},
            "width" => %{"type" => "integer"},
            "height" => %{"type" => "integer"}
          },
          "description" => "Screenshot region {x, y, width, height}"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => action} = args) do
    with :ok <- validate_action(action),
         :ok <- validate_args(action, args) do
      __MODULE__.MacOS.run(action, args)
    end
  end

  def execute(_), do: {:error, "Missing required parameter: action"}

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_action(action) when action in @valid_actions, do: :ok
  defp validate_action(action), do: {:error, "Invalid action: #{inspect(action)}. Must be one of: #{Enum.join(@valid_actions, ", ")}"}

  defp validate_args("screenshot", args) do
    case Map.get(args, "region") do
      nil -> :ok
      region -> validate_region(region)
    end
  end

  defp validate_args(action, args) when action in ~w(click double_click move_mouse) do
    with :ok <- require_coordinate(args, "x"),
         :ok <- require_coordinate(args, "y") do
      :ok
    end
  end

  defp validate_args("drag", args) do
    # Drag needs start (x,y) — end position encoded in text as "end_x,end_y"
    # or we can use region for end coordinates
    with :ok <- require_coordinate(args, "x"),
         :ok <- require_coordinate(args, "y") do
      :ok
    end
  end

  defp validate_args("type", args) do
    case Map.get(args, "text") do
      nil -> {:error, "Missing required parameter: text (for type action)"}
      text when is_binary(text) -> validate_text(text)
      _ -> {:error, "Parameter text must be a string"}
    end
  end

  defp validate_args("key", args) do
    case Map.get(args, "text") do
      nil -> {:error, "Missing required parameter: text (for key action, e.g. \"cmd+c\", \"enter\")"}
      text when is_binary(text) -> validate_key_combo(text)
      _ -> {:error, "Parameter text must be a string"}
    end
  end

  defp validate_args("scroll", args) do
    case Map.get(args, "direction") do
      nil -> {:error, "Missing required parameter: direction (for scroll action)"}
      dir when dir in @valid_directions -> :ok
      dir -> {:error, "Invalid direction: #{inspect(dir)}. Must be one of: #{Enum.join(@valid_directions, ", ")}"}
    end
  end

  defp validate_args(_, _), do: :ok

  defp require_coordinate(args, key) do
    case Map.get(args, key) do
      nil -> {:error, "Missing required parameter: #{key}"}
      val when is_integer(val) and val >= 0 -> :ok
      val when is_integer(val) -> {:error, "Parameter #{key} must be non-negative, got: #{val}"}
      _ -> {:error, "Parameter #{key} must be an integer"}
    end
  end

  defp validate_region(%{"x" => x, "y" => y, "width" => w, "height" => h})
       when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h)
       and x >= 0 and y >= 0 and w > 0 and h > 0 do
    :ok
  end

  defp validate_region(_) do
    {:error, "Region must have integer x, y (>= 0) and width, height (> 0)"}
  end

  defp validate_text(text) do
    cond do
      byte_size(text) == 0 -> {:error, "Text must not be empty"}
      byte_size(text) > @max_text_length -> {:error, "Text exceeds maximum length of #{@max_text_length} bytes"}
      true -> :ok
    end
  end

  # Key combos must only contain safe characters: alphanumerics, modifiers, +, -, space
  @key_combo_pattern ~r/\A[a-zA-Z0-9+\-_ ]+\z/

  defp validate_key_combo(text) do
    cond do
      byte_size(text) == 0 ->
        {:error, "Key combo must not be empty"}

      byte_size(text) > 100 ->
        {:error, "Key combo too long (max 100 chars)"}

      not Regex.match?(@key_combo_pattern, text) ->
        {:error, "Key combo contains invalid characters. Use alphanumerics, +, -, space only (e.g. \"cmd+c\", \"enter\")"}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # MacOS — platform-specific implementation
  # ---------------------------------------------------------------------------

  defmodule MacOS do
    @moduledoc false

    require Logger

    @screenshot_dir Path.expand("~/.osa/screenshots")

    @doc "Execute a computer_use action on macOS."
    def run("screenshot", args) do
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
        case Map.get(args, "region") do
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

    def run("click", %{"x" => x, "y" => y}) do
      applescript_click(x, y, 1)
    end

    def run("double_click", %{"x" => x, "y" => y}) do
      applescript_click(x, y, 2)
    end

    def run("type", %{"text" => text}) do
      # Sanitize text for AppleScript — escape backslashes and double quotes
      escaped = sanitize_for_applescript(text)

      script = ~s(tell application "System Events" to keystroke "#{escaped}")

      run_osascript(script, "type")
    end

    def run("key", %{"text" => combo}) do
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

    def run("scroll", args) do
      direction = Map.fetch!(args, "direction")
      amount = Map.get(args, "amount", 3)

      {dx, dy} =
        case direction do
          "up" -> {0, amount}
          "down" -> {0, -amount}
          "left" -> {amount, 0}
          "right" -> {-amount, 0}
        end

      # Use AppleScript + Cocoa bridge for scroll events
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

    def run("move_mouse", %{"x" => x, "y" => y}) do
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

    def run("drag", %{"x" => x, "y" => y} = args) do
      # End coordinates from region or default to same point
      {end_x, end_y} =
        case Map.get(args, "region") do
          %{"x" => ex, "y" => ey} -> {ex, ey}
          _ -> {x, y}
        end

      script = """
      do shell script "
      /usr/bin/python3 -c '
      import Quartz, time
      # Mouse down at start
      e1 = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventLeftMouseDown, (#{x}, #{y}), Quartz.kCGMouseButtonLeft)
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

    # ---------------------------------------------------------------------------
    # AppleScript helpers
    # ---------------------------------------------------------------------------

    defp applescript_click(x, y, count) do
      # Use Python/Quartz for reliable coordinate clicking
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

    @doc false
    def sanitize_for_applescript(text) do
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
    end

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

    # Parse "cmd+shift+c" into {["cmd", "shift"], "c"}
    @doc false
    def parse_key_combo(combo) do
      parts = combo |> String.downcase() |> String.split("+", trim: true) |> Enum.map(&String.trim/1)

      modifiers = ~w(cmd command ctrl control alt option shift fn)

      case Enum.split_with(parts, fn p -> p in modifiers end) do
        {mods, [key]} -> {mods, key}
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

    # Map common key names to macOS virtual key codes
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

    defp key_name_to_code(key) do
      Map.get(@key_codes, String.downcase(key))
    end
  end
end
