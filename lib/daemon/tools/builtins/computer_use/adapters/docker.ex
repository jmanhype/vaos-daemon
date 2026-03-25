defmodule Daemon.Tools.Builtins.ComputerUse.Adapters.Docker do
  @moduledoc """
  Computer use adapter that forwards all input/output primitives to a Docker
  container via `docker exec`.

  The primary use-case is the Anthropic computer-use reference image (or any
  container that ships Xvfb + xdotool). Screenshots are taken inside the
  container and then copied to the host via `docker cp`.

  ## Configuration

      config :daemon, :computer_use_docker,
        container: "osa-desktop",         # container name or ID  (required)
        display: ":1",                     # DISPLAY env var inside container
        screenshot_path: "/tmp/screenshots" # directory inside container

  ## Availability

  The adapter reports `available?/0 == true` only when:

  1. Configuration key `:computer_use_docker` is present and contains a
     `:container` value.
  2. The `docker` executable is on the host `$PATH`.
  3. `docker inspect` confirms the named container is currently running.

  ## Key Notes

  - All GUI commands are run via `DISPLAY=<display> <cmd>` inside the container.
  - `type_text/1` shell-escapes the input to prevent injection.
  - `get_accessibility_tree/1` is not implemented — returns a descriptive error
    so callers can fall back to screenshot mode.
  - `test_connection/0` is a public diagnostic helper, not part of the Adapter
    behaviour contract.
  """

  @behaviour Daemon.Tools.Builtins.ComputerUse.Adapter

  require Logger

  @local_screenshot_dir Path.expand("~/.daemon/screenshots")

  # ---------------------------------------------------------------------------
  # xdotool / X11 key name map (identical to LinuxX11 adapter)
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
  def platform, do: :docker

  @impl true
  def available? do
    config = get_config()

    case config[:container] do
      nil ->
        false

      "" ->
        false

      container ->
        System.find_executable("docker") != nil and container_running?(container)
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: screenshot
  # ---------------------------------------------------------------------------

  @impl true
  def screenshot(opts) do
    config = get_config()
    screenshot_dir = config[:screenshot_path] || "/tmp"
    timestamp = System.system_time(:millisecond)
    container_path = "#{screenshot_dir}/osa_screenshot_#{timestamp}.png"

    region = Map.get(opts, "region")

    capture_cmd =
      case region do
        %{"x" => x, "y" => y, "width" => w, "height" => h} ->
          # maim supports --geometry; scrot supports -a; try maim first
          "(maim --geometry #{w}x#{h}+#{x}+#{y} #{container_path} 2>/dev/null) || " <>
            "scrot -a #{x},#{y},#{w},#{h} #{container_path}"

        _ ->
          "(maim #{container_path} 2>/dev/null) || scrot #{container_path}"
      end

    with {:ok, _} <- docker_exec(capture_cmd),
         {:ok, local_path} <- fetch_container_screenshot(container_path) do
      {:ok, "Screenshot saved to #{local_path}. Use file_read to view it."}
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: mouse actions
  # ---------------------------------------------------------------------------

  @impl true
  def click(x, y, opts) do
    button = Map.get(opts, "button", 1)

    case docker_exec("xdotool mousemove #{x} #{y} click #{button}") do
      {:ok, _} -> {:ok, "Clicked at (#{x}, #{y}) with button #{button}."}
      error -> error
    end
  end

  @impl true
  def double_click(x, y) do
    case docker_exec("xdotool mousemove #{x} #{y} click --repeat 2 1") do
      {:ok, _} -> {:ok, "Double-clicked at (#{x}, #{y})."}
      error -> error
    end
  end

  @impl true
  def move_mouse(x, y) do
    case docker_exec("xdotool mousemove #{x} #{y}") do
      {:ok, _} -> {:ok, "Mouse moved to (#{x}, #{y})."}
      error -> error
    end
  end

  @impl true
  def drag(start_x, start_y, end_x, end_y) do
    cmd =
      "xdotool mousemove #{start_x} #{start_y} mousedown 1 " <>
        "mousemove #{end_x} #{end_y} mouseup 1"

    case docker_exec(cmd) do
      {:ok, _} ->
        {:ok, "Dragged from (#{start_x}, #{start_y}) to (#{end_x}, #{end_y})."}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour: keyboard actions
  # ---------------------------------------------------------------------------

  @impl true
  def type_text(text) do
    case docker_exec("xdotool type --clearmodifiers #{shell_escape(text)}") do
      {:ok, _} -> {:ok, "Typed text successfully."}
      error -> error
    end
  end

  @impl true
  def key_press(combo) do
    xdotool_combo = parse_key_combo(combo)

    case docker_exec("xdotool key #{xdotool_combo}") do
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

    case docker_exec("xdotool click --repeat #{amount} #{button}") do
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
    {:error,
     "Accessibility tree not yet implemented for Docker adapter. Use screenshot fallback."}
  end

  # ---------------------------------------------------------------------------
  # Public diagnostic helper
  # ---------------------------------------------------------------------------

  @doc """
  Test Docker container connectivity.

  Runs `uname -a && which xdotool` inside the container to confirm the
  environment is healthy. Returns `{:ok, info_map}` on success or
  `{:error, reason}` on failure.

  Not part of the `Adapter` behaviour — intended for health checks and
  debugging only.
  """
  @spec test_connection() :: {:ok, map()} | {:error, String.t()}
  def test_connection do
    config = get_config()
    container = config[:container]

    with {:ok, _} <- check_container_running(container),
         {:ok, output} <- docker_exec("uname -a && which xdotool") do
      {:ok, %{connected: true, container: container, system: output}}
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
  # Private helpers
  # ---------------------------------------------------------------------------

  # Run a shell command inside the container with DISPLAY set.
  defp docker_exec(command) do
    config = get_config()
    container = config[:container]
    display = config[:display] || ":1"

    full_command = "DISPLAY=#{display} #{command}"

    case System.cmd(
           "docker",
           ["exec", container, "bash", "-c", full_command],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, code} ->
        trimmed = String.trim(output)
        Logger.warning("docker exec exited #{code}: #{trimmed}")
        {:error, "docker exec failed (exit #{code}): #{trimmed}"}
    end
  rescue
    e ->
      Logger.error("docker exec raised: #{Exception.message(e)}")
      {:error, "docker exec raised: #{Exception.message(e)}"}
  end

  # Copy a file from the container to the local host.
  # Returns {:ok, local_path} and cleans up the container-side file.
  defp fetch_container_screenshot(container_path) do
    config = get_config()
    container = config[:container]
    local_dir = ensure_local_screenshot_dir()
    timestamp = System.system_time(:millisecond)
    local_path = Path.join(local_dir, "docker_screenshot_#{timestamp}.png")

    case System.cmd(
           "docker",
           ["cp", "#{container}:#{container_path}", local_path],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        # Best-effort cleanup — ignore errors
        docker_exec("rm -f #{container_path}")
        {:ok, local_path}

      {output, code} ->
        trimmed = String.trim(output)
        Logger.warning("docker cp failed (exit #{code}): #{trimmed}")
        {:error, "docker cp failed (exit #{code}): #{trimmed}"}
    end
  rescue
    e ->
      Logger.error("docker cp raised: #{Exception.message(e)}")
      {:error, "docker cp raised: #{Exception.message(e)}"}
  end

  # Returns true when the container is in the Running state.
  defp container_running?(container) do
    case System.cmd(
           "docker",
           ["inspect", "-f", "{{.State.Running}}", container],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  rescue
    _ -> false
  end

  # Same logic as container_running? but surfaces the error for with-chains.
  defp check_container_running(container) do
    case System.cmd(
           "docker",
           ["inspect", "-f", "{{.State.Running}}", container],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        if String.trim(output) == "true" do
          {:ok, true}
        else
          {:error, "Container #{container} is not running"}
        end

      {output, _code} ->
        {:error, "Container #{container} is not running: #{String.trim(output)}"}
    end
  rescue
    e ->
      {:error, "docker inspect raised: #{Exception.message(e)}"}
  end

  defp ensure_local_screenshot_dir do
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

  # Single-quote shell escaping: ' -> '\''
  defp shell_escape(text) do
    "'" <> String.replace(text, "'", "'\\''") <> "'"
  end

  defp get_config do
    Application.get_env(:daemon, :computer_use_docker, [])
  end
end
