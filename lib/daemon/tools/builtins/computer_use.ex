defmodule Daemon.Tools.Builtins.ComputerUse do
  @moduledoc """
  Computer use tool — take screenshots, click, type, scroll, drag, and inspect
  the accessibility tree on any supported platform.

  Delegates execution to `ComputerUse.Server`, a GenServer that detects the
  platform, selects the appropriate adapter (macOS, Linux X11, Linux Wayland),
  caches the accessibility tree, and dispatches actions. The server starts
  lazily on first use.

  Element refs (e0, e1, e2...) can be retrieved via the `get_tree` action and
  used as the `target` parameter on `click`, giving reliable structured
  targeting instead of raw coordinates.

  Safety: `:write_destructive` — every action except screenshot requires user
  confirmation via the permission system.

  Gated by the `:computer_use_enabled` application config flag (default `false`).
  """

  @behaviour MiosaTools.Behaviour

  require Logger

  alias Daemon.Tools.Builtins.ComputerUse.Server, as: ComputerUseServer

  @valid_actions ~w(screenshot click double_click type key scroll move_mouse drag get_tree)
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
    "Control the computer — take screenshots, click at coordinates or element refs, " <>
      "type text, press keys, scroll, drag. Use get_tree to inspect the accessibility " <>
      "tree and target elements by ref (e0, e1...) for reliable clicking."
  end

  @impl true
  def safety, do: :write_destructive

  @impl true
  def available? do
    Application.get_env(:daemon, :computer_use_enabled, false) == true
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => @valid_actions,
          "description" =>
            "Action to perform: screenshot, click, double_click, type, key, scroll, " <>
              "move_mouse, drag, get_tree"
        },
        "x" => %{
          "type" => "integer",
          "description" => "X coordinate for click/move/drag actions"
        },
        "y" => %{
          "type" => "integer",
          "description" => "Y coordinate for click/move/drag actions"
        },
        "target" => %{
          "type" => "string",
          "description" =>
            "Element ref from get_tree (e.g. \"e0\", \"e1\") — use instead of x/y " <>
              "coordinates for reliable clicking on labelled elements"
        },
        "text" => %{
          "type" => "string",
          "description" =>
            "Text to type (for type action) or key combo (for key action, " <>
              "e.g. \"cmd+c\", \"enter\", \"tab\")"
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
        },
        "force_refresh" => %{
          "type" => "boolean",
          "description" =>
            "Force a fresh accessibility tree fetch even if a cached one exists (for get_tree)"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => action} = args) do
    with :ok <- validate_action(action),
         :ok <- validate_args(action, args),
         :ok <- ensure_server_started() do
      ComputerUseServer.execute(action, args)
    end
  end

  def execute(_), do: {:error, "Missing required parameter: action"}

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_action(action) when action in @valid_actions, do: :ok

  defp validate_action(action) do
    {:error,
     "Invalid action: #{inspect(action)}. Must be one of: #{Enum.join(@valid_actions, ", ")}"}
  end

  # screenshot: optional region
  defp validate_args("screenshot", args) do
    case Map.get(args, "region") do
      nil -> :ok
      region -> validate_region(region)
    end
  end

  # click: requires either (x,y) or target — both paths are valid
  defp validate_args("click", args) do
    has_target = Map.has_key?(args, "target")
    has_coords = Map.has_key?(args, "x") && Map.has_key?(args, "y")

    cond do
      has_target ->
        validate_element_ref(Map.fetch!(args, "target"))

      has_coords ->
        with :ok <- require_coordinate(args, "x"),
             :ok <- require_coordinate(args, "y") do
          :ok
        end

      true ->
        {:error,
         "click requires either coordinates (x, y) or a target element ref (e.g. \"e0\")"}
    end
  end

  defp validate_args(action, args) when action in ~w(double_click move_mouse) do
    with :ok <- require_coordinate(args, "x"),
         :ok <- require_coordinate(args, "y") do
      :ok
    end
  end

  defp validate_args("drag", args) do
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
      nil ->
        {:error, "Missing required parameter: text (for key action, e.g. \"cmd+c\", \"enter\")"}

      text when is_binary(text) ->
        validate_key_combo(text)

      _ ->
        {:error, "Parameter text must be a string"}
    end
  end

  defp validate_args("scroll", args) do
    case Map.get(args, "direction") do
      nil ->
        {:error, "Missing required parameter: direction (for scroll action)"}

      dir when dir in @valid_directions ->
        :ok

      dir ->
        {:error,
         "Invalid direction: #{inspect(dir)}. Must be one of: #{Enum.join(@valid_directions, ", ")}"}
    end
  end

  # get_tree has no required params
  defp validate_args("get_tree", _args), do: :ok

  defp validate_args(_, _), do: :ok

  defp require_coordinate(args, key) do
    case Map.get(args, key) do
      nil -> {:error, "Missing required parameter: #{key}"}
      val when is_integer(val) and val >= 0 -> :ok
      val when is_integer(val) -> {:error, "Parameter #{key} must be non-negative, got: #{val}"}
      _ -> {:error, "Parameter #{key} must be an integer"}
    end
  end

  defp validate_element_ref(ref) when is_binary(ref) and byte_size(ref) > 0, do: :ok
  defp validate_element_ref(_), do: {:error, "target must be a non-empty string element ref (e.g. \"e0\")"}

  defp validate_region(%{"x" => x, "y" => y, "width" => w, "height" => h})
       when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h) and
              x >= 0 and y >= 0 and w > 0 and h > 0 do
    :ok
  end

  defp validate_region(_) do
    {:error, "Region must have integer x, y (>= 0) and width, height (> 0)"}
  end

  defp validate_text(text) do
    cond do
      byte_size(text) == 0 ->
        {:error, "Text must not be empty"}

      byte_size(text) > @max_text_length ->
        {:error, "Text exceeds maximum length of #{@max_text_length} bytes"}

      true ->
        :ok
    end
  end

  # Key combos must only contain safe characters: alphanumerics, modifiers, +, -, space
  @key_combo_pattern_source {~S"\A[a-zA-Z0-9+\-_ ]+\z", ""}

  defp validate_key_combo(text) do
    cond do
      byte_size(text) == 0 ->
        {:error, "Key combo must not be empty"}

      byte_size(text) > 100 ->
        {:error, "Key combo too long (max 100 chars)"}

      not key_combo_valid?(text) ->
        {:error,
         "Key combo contains invalid characters. Use alphanumerics, +, -, space only " <>
           "(e.g. \"cmd+c\", \"enter\")"}

      true ->
        :ok
    end
  end

  defp key_combo_valid?(text) do
    {src, opts} = @key_combo_pattern_source
    Regex.match?(Regex.compile!(src, opts), text)
  end

  # ---------------------------------------------------------------------------
  # Server lifecycle
  # ---------------------------------------------------------------------------

  defp ensure_server_started do
    case Process.whereis(ComputerUseServer) do
      nil ->
        case ComputerUseServer.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, "Failed to start ComputerUse server: #{inspect(reason)}"}
        end

      _pid ->
        :ok
    end
  end
end
