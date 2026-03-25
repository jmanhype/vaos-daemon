defmodule Daemon.Tools.Builtins.ComputerUse.Adapter do
  @moduledoc """
  Behaviour contract for platform-specific computer use adapters.

  Each adapter implements the full set of input/output primitives for a target
  platform (macOS, Linux X11, Linux Wayland). The `ComputerUse` tool delegates
  to the adapter returned by `adapter_for(detect_platform/0)`.

  All callbacks return `{:ok, result}` on success or `{:error, reason}` on
  failure. Callers must not assume a particular result type beyond that contract.

  `get_accessibility_tree/1` is optional — adapters that do not yet implement
  it should return `{:error, "Accessibility tree not implemented for <platform>"}`.
  """

  @optional_callbacks [get_accessibility_tree: 1]

  @doc "Identifies which platform this adapter targets."
  @callback platform() :: :macos | :linux_x11 | :linux_wayland | :windows | :remote_ssh | :docker | :platform_vm

  @doc """
  Returns true when the adapter is usable on the current host.

  Implementations should check OS type and any required external tools or
  permissions (e.g. Accessibility API authorisation on macOS).
  """
  @callback available?() :: boolean()

  @doc """
  Capture a screenshot of the current display.

  Accepts an optional `opts` map with a `"region"` key:
  `%{"x" => x, "y" => y, "width" => w, "height" => h}`.
  When absent, the full display is captured.

  On success, returns the path at which the image was saved.
  """
  @callback screenshot(opts :: map()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "Send a single mouse click at the given screen coordinates."
  @callback click(x :: integer(), y :: integer(), opts :: map()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc "Send a double mouse click at the given screen coordinates."
  @callback double_click(x :: integer(), y :: integer()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc "Type a string of text via the system keyboard input channel."
  @callback type_text(text :: String.t()) :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Press a key combination.

  `combo` is a `+`-separated string such as `"cmd+c"`, `"shift+enter"`, or
  `"escape"`. Modifier names are normalised by the adapter (cmd/command,
  ctrl/control, alt/option, shift, fn).
  """
  @callback key_press(combo :: String.t()) :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Scroll in the given direction by `amount` units.

  `direction` is one of `"up"`, `"down"`, `"left"`, `"right"`.
  `amount` is in scroll-wheel units (not pixels).
  """
  @callback scroll(direction :: String.t(), amount :: integer()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc "Move the mouse cursor to the given screen coordinates without clicking."
  @callback move_mouse(x :: integer(), y :: integer()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc """
  Click and drag from `(start_x, start_y)` to `(end_x, end_y)`.

  Implementations must synthesise a mouse-down event at the start point, a
  drag event to the end point, and a mouse-up event at the end point.
  """
  @callback drag(
              start_x :: integer(),
              start_y :: integer(),
              end_x :: integer(),
              end_y :: integer()
            ) :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Return the platform accessibility tree as a structured map.

  This callback is optional. Adapters that have not yet wired up the native
  accessibility APIs should return `{:error, "not implemented"}` rather than
  raising.
  """
  @callback get_accessibility_tree(opts :: map()) :: {:ok, map()} | {:error, String.t()}

  # ---------------------------------------------------------------------------
  # Platform detection
  # ---------------------------------------------------------------------------

  @doc """
  Detect the current host platform and return a normalised atom.

  Detection logic (checked in order):
  1. If `config :daemon, :computer_use_vm` has a `:sprite_id` set,
     return `:platform_vm` — Firecracker microVM takes highest priority.
  2. If `config :daemon, :computer_use_docker` has a `:container` set,
     return `:docker`.
  3. If `config :daemon, :computer_use_remote` has a `:host` set,
     return `:remote_ssh`.
  4. `{:unix, :darwin}` → `:macos`
  5. `{:unix, :linux}` with `WAYLAND_DISPLAY` set or `XDG_SESSION_TYPE=wayland` → `:linux_wayland`
  6. `{:unix, :linux}` otherwise → `:linux_x11`
  7. `{:win32, _}` → `:windows`
  """
  @spec detect_platform() :: :macos | :linux_x11 | :linux_wayland | :windows | :remote_ssh | :docker | :platform_vm
  def detect_platform do
    vm_config = Application.get_env(:daemon, :computer_use_vm, [])
    vm_sprite = vm_config[:sprite_id]

    docker_config = Application.get_env(:daemon, :computer_use_docker, [])
    docker_container = docker_config[:container]

    remote_config = Application.get_env(:daemon, :computer_use_remote, [])
    remote_host = remote_config[:host]

    cond do
      vm_sprite not in [nil, ""] ->
        :platform_vm

      docker_container not in [nil, ""] ->
        :docker

      remote_host not in [nil, ""] ->
        :remote_ssh

      true ->
        case :os.type() do
          {:unix, :darwin} ->
            :macos

          {:unix, :linux} ->
            wayland_display = System.get_env("WAYLAND_DISPLAY")
            xdg_session = System.get_env("XDG_SESSION_TYPE")

            if wayland_display not in [nil, ""] or xdg_session == "wayland" do
              :linux_wayland
            else
              :linux_x11
            end

          {:win32, _} ->
            :windows

          _ ->
            :linux_x11
        end
    end
  end

  @doc """
  Return the adapter module for the given platform atom.

  Returns `{:ok, module}` when a mapping exists, or `{:error, reason}` when
  the platform is not yet supported.
  """
  @spec adapter_for(:macos | :linux_x11 | :linux_wayland | :windows | :remote_ssh | :docker | :platform_vm) ::
          {:ok, module()} | {:error, String.t()}
  def adapter_for(:macos),
    do: {:ok, Daemon.Tools.Builtins.ComputerUse.Adapters.MacOS}

  def adapter_for(:linux_x11),
    do: {:ok, Daemon.Tools.Builtins.ComputerUse.Adapters.LinuxX11}

  def adapter_for(:linux_wayland),
    do: {:ok, Daemon.Tools.Builtins.ComputerUse.Adapters.LinuxWayland}

  def adapter_for(:remote_ssh),
    do: {:ok, Daemon.Tools.Builtins.ComputerUse.Adapters.RemoteSSH}

  def adapter_for(:docker),
    do: {:ok, Daemon.Tools.Builtins.ComputerUse.Adapters.Docker}

  def adapter_for(:platform_vm),
    do: {:ok, Daemon.Tools.Builtins.ComputerUse.Adapters.PlatformVM}

  def adapter_for(:windows),
    do: {:error, "Windows platform is not yet supported"}

  def adapter_for(other),
    do: {:error, "Unknown platform: #{inspect(other)}"}
end
