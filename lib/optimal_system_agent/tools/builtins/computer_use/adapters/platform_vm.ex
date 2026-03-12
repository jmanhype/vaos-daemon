defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.PlatformVM do
  @moduledoc """
  Computer use adapter that forwards desktop control commands to a Firecracker
  microVM managed by the Sprites.dev sandbox backend
  (`OptimalSystemAgent.Sandbox.Sprites`).

  The VMs run Linux with Xvfb + xdotool, so all GUI primitives use the same
  X11 command set as the Docker and LinuxX11 adapters.

  ## Configuration

      config :optimal_system_agent, :computer_use_vm,
        sprite_id: "abc123",   # Sprites.dev VM identifier (required)
        display: ":1"          # DISPLAY env var inside the VM

  ## Availability

  The adapter reports `available?/0 == true` only when:

  1. Configuration key `:computer_use_vm` is present and contains a non-empty
     `:sprite_id` value.
  2. `Sprites.available?()` returns true (i.e. `SPRITES_TOKEN` is set).

  ## Screenshot transfer

  Since we cannot SCP from a Sprites VM, screenshots are captured via
  `maim` inside the VM, then base64-encoded in-VM and decoded on the host.
  Local files land in `~/.osa/screenshots/`.

  ## Key Notes

  - All GUI commands are run via `DISPLAY=<display> <cmd>` inside the VM.
  - `type_text/1` shell-escapes the input to prevent injection.
  - `get_accessibility_tree/1` is not implemented -- returns a descriptive error
    so callers can fall back to screenshot mode.
  - `test_connection/0` is a public diagnostic helper, not part of the Adapter
    behaviour contract.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  alias OptimalSystemAgent.Sandbox.Sprites

  require Logger

  @local_screenshot_dir Path.expand("~/.osa/screenshots")

  # ---------------------------------------------------------------------------
  # xdotool / X11 key name map (identical to Docker/LinuxX11 adapters)
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
    # Modifiers -- Linux maps Cmd/Command to the Super key
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
  def platform, do: :platform_vm

  @impl true
  def available? do
    config = get_config()

    case config[:sprite_id] do
      nil -> false
      "" -> false
      _sprite_id -> Sprites.available?()
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: screenshot
  # ---------------------------------------------------------------------------

  @impl true
  def screenshot(opts) do
    remote_path = "/tmp/osa_screenshot_#{timestamp()}.png"
    region = Map.get(opts, "region")

    capture_cmd =
      case region do
        %{"x" => x, "y" => y, "width" => w, "height" => h} ->
          "maim --geometry #{w}x#{h}+#{x}+#{y} #{remote_path}"

        _ ->
          "maim #{remote_path}"
      end

    # Capture, then base64-encode in-VM (no SCP from Sprites VMs)
    with {:ok, _output, 0} <- vm_exec(capture_cmd),
         {:ok, b64_output, 0} <- vm_exec("base64 -w 0 #{remote_path}"),
         {:ok, local_path} <- decode_and_save_screenshot(b64_output) do
      # Best-effort remote cleanup
      vm_exec("rm -f #{remote_path}")
      {:ok, "Screenshot saved to #{local_path}. Use file_read to view it."}
    else
      {:ok, _output, code} ->
        {:error, "Screenshot command failed (exit #{code})"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: mouse actions
  # ---------------------------------------------------------------------------

  @impl true
  def click(x, y, opts) do
    button = Map.get(opts, "button", 1)

    case vm_exec("xdotool mousemove #{x} #{y} click #{button}") do
      {:ok, _, 0} -> {:ok, "Clicked at (#{x}, #{y}) with button #{button} in VM."}
      {:ok, _, code} -> {:error, "xdotool click failed (exit #{code})"}
      error -> error
    end
  end

  @impl true
  def double_click(x, y) do
    case vm_exec("xdotool mousemove #{x} #{y} click --repeat 2 1") do
      {:ok, _, 0} -> {:ok, "Double-clicked at (#{x}, #{y}) in VM."}
      {:ok, _, code} -> {:error, "xdotool double-click failed (exit #{code})"}
      error -> error
    end
  end

  @impl true
  def move_mouse(x, y) do
    case vm_exec("xdotool mousemove #{x} #{y}") do
      {:ok, _, 0} -> {:ok, "Mouse moved to (#{x}, #{y}) in VM."}
      {:ok, _, code} -> {:error, "xdotool mousemove failed (exit #{code})"}
      error -> error
    end
  end

  @impl true
  def drag(start_x, start_y, end_x, end_y) do
    cmd =
      "xdotool mousemove #{start_x} #{start_y} mousedown 1 " <>
        "mousemove #{end_x} #{end_y} mouseup 1"

    case vm_exec(cmd) do
      {:ok, _, 0} ->
        {:ok, "Dragged from (#{start_x}, #{start_y}) to (#{end_x}, #{end_y}) in VM."}

      {:ok, _, code} ->
        {:error, "xdotool drag failed (exit #{code})"}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: keyboard actions
  # ---------------------------------------------------------------------------

  @impl true
  def type_text(text) do
    case vm_exec("xdotool type --clearmodifiers #{shell_escape(text)}") do
      {:ok, _, 0} -> {:ok, "Typed text successfully in VM."}
      {:ok, _, code} -> {:error, "xdotool type failed (exit #{code})"}
      error -> error
    end
  end

  @impl true
  def key_press(combo) do
    xdotool_combo = parse_key_combo(combo)

    case vm_exec("xdotool key #{xdotool_combo}") do
      {:ok, _, 0} -> {:ok, "Key combo '#{combo}' sent (xdotool: '#{xdotool_combo}') in VM."}
      {:ok, _, code} -> {:error, "xdotool key failed (exit #{code})"}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: scroll
  # ---------------------------------------------------------------------------

  @impl true
  def scroll(direction, amount) do
    button = scroll_button(direction)

    case vm_exec("xdotool click --repeat #{amount} #{button}") do
      {:ok, _, 0} -> {:ok, "Scrolled #{direction} by #{amount} units in VM."}
      {:ok, _, code} -> {:error, "xdotool scroll failed (exit #{code})"}
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
    {:error, "Accessibility tree not yet implemented for PlatformVM adapter. Use screenshot fallback."}
  end

  # ---------------------------------------------------------------------------
  # Public diagnostic helper
  # ---------------------------------------------------------------------------

  @doc """
  Test Sprites VM connectivity.

  Runs `uname -a && which xdotool` inside the VM to confirm the environment
  is healthy. Returns `{:ok, info_map}` on success or `{:error, reason}` on
  failure.

  Not part of the `Adapter` behaviour -- intended for health checks and
  debugging only.
  """
  @spec test_connection() :: {:ok, map()} | {:error, String.t()}
  def test_connection do
    config = get_config()
    sprite_id = config[:sprite_id]

    case vm_exec("uname -a && which xdotool") do
      {:ok, output, 0} ->
        preview =
          case Sprites.preview_url(sprite_id) do
            {:ok, url} -> url
            _ -> nil
          end

        {:ok, %{connected: true, sprite_id: sprite_id, system: output, preview_url: preview}}

      {:ok, output, code} ->
        {:error, "VM health check failed (exit #{code}): #{output}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Key combo parsing
  # ---------------------------------------------------------------------------

  @doc """
  Convert a human-readable key combo like `"cmd+shift+c"` to the xdotool
  keysym format `"super+shift+c"`.

  Each `+`-separated token is looked up in `@key_map`. Tokens not present
  (e.g. ordinary alphanumeric keys) are passed through unchanged.
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
  # Shell escaping
  # ---------------------------------------------------------------------------

  @doc """
  Wrap `text` in single quotes, escaping any embedded single quotes.

  The technique `'...'\\''...'` ends the current single-quoted segment,
  appends a literal single-quote via `\\'`, then re-opens a new single-quoted
  segment. This is the POSIX-portable approach and prevents command injection
  when interpolating arbitrary user text into a shell command string.

  ## Examples

      iex> PlatformVM.shell_escape("hello world")
      "'hello world'"

      iex> PlatformVM.shell_escape("it's a test")
      "'it'\\\\''s a test'"
  """
  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(text) do
    "'" <> String.replace(text, "'", "'\\''") <> "'"
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Execute a command inside the Sprites VM with DISPLAY set.
  # Returns the raw Sprites.execute/2 result: {:ok, output, exit_code} | {:error, reason}
  defp vm_exec(command) do
    config = get_config()
    sprite_id = config[:sprite_id]
    display = config[:display] || ":1"

    full_command = "DISPLAY=#{display} #{command}"

    Logger.debug("[PlatformVM] executing in sprite #{sprite_id}: #{full_command}")

    case Sprites.execute(full_command, sprite_id: sprite_id) do
      {:ok, output, exit_code} ->
        {:ok, String.trim(output), exit_code}

      {:error, reason} ->
        Logger.warning("[PlatformVM] Sprites.execute failed: #{inspect(reason)}")
        {:error, "Sprites VM exec failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      Logger.error("[PlatformVM] vm_exec raised: #{Exception.message(e)}")
      {:error, "Sprites VM exec raised: #{Exception.message(e)}"}
  end

  # Decode base64-encoded PNG data and write it to the local screenshot directory.
  defp decode_and_save_screenshot(b64_data) do
    local_dir = ensure_screenshot_dir()
    local_path = Path.join(local_dir, "vm_screenshot_#{timestamp()}.png")

    case Base.decode64(String.trim(b64_data)) do
      {:ok, png_bytes} ->
        File.write!(local_path, png_bytes)
        {:ok, local_path}

      :error ->
        Logger.warning("[PlatformVM] Failed to decode base64 screenshot data")
        {:error, "Failed to decode base64 screenshot data from VM"}
    end
  rescue
    e ->
      Logger.error("[PlatformVM] screenshot save raised: #{Exception.message(e)}")
      {:error, "Screenshot save failed: #{Exception.message(e)}"}
  end

  defp ensure_screenshot_dir do
    try do
      File.mkdir_p!(@local_screenshot_dir)
      @local_screenshot_dir
    rescue
      _ ->
        fallback = Path.join(System.tmp_dir!(), "osa_screenshots")
        File.mkdir_p!(fallback)
        fallback
    end
  end

  defp get_config do
    Application.get_env(:optimal_system_agent, :computer_use_vm, [])
  end

  defp timestamp, do: System.system_time(:millisecond)
end
