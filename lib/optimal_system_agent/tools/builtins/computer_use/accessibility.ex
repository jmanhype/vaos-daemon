defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Accessibility do
  @moduledoc """
  Accessibility tree parsing, element ref assignment, and diffing.

  Normalizes accessibility tree output from platform-specific tools
  (macOS AXUIElement, Linux AT-SPI2) into a unified format with
  element refs for structured interaction.

  The accessibility tree approach uses ~800 tokens/page vs ~10,000+
  for screenshots, providing 5-13x cost reduction while improving
  reliability through deterministic element targeting.
  """

  @typedoc "A normalized accessibility tree node"
  @type node_t :: %{
          role: String.t(),
          name: String.t() | nil,
          value: String.t() | nil,
          bounds: bounds() | nil,
          ref: String.t() | nil,
          state: [String.t()],
          children: [node_t()]
        }

  @typedoc "Bounding rectangle"
  @type bounds :: %{x: integer(), y: integer(), width: integer(), height: integer()}

  @typedoc "Element ref map: ref_id => center coordinates"
  @type ref_map :: %{String.t() => %{x: integer(), y: integer()}}

  @interactive_roles ~w(button link textfield textarea checkbox radio menuitem
                        tab slider combobox switch toggle searchfield
                        incrementor decrementor disclosure popupbutton
                        menubar toolbar)

  # ---------------------------------------------------------------------------
  # Element Ref Assignment
  # ---------------------------------------------------------------------------

  @doc """
  Walk a normalized tree and assign element refs (e0, e1, e2...) to
  all interactive elements. Returns {ref_map, annotated_tree}.

  ## Example

      {refs, tree} = assign_refs(tree)
      # refs = %{"e0" => %{x: 500, y: 300}, "e1" => %{x: 200, y: 150}}
  """
  @spec assign_refs(map(), non_neg_integer()) :: {ref_map(), map()}
  def assign_refs(tree, start_counter \\ 0) do
    {refs, _counter, annotated} = walk_and_assign(tree, %{}, start_counter)
    {refs, annotated}
  end

  defp walk_and_assign(%{"children" => children} = node, refs, counter) do
    {counter, refs, node} = maybe_assign_ref(node, refs, counter)

    {child_refs, child_counter, annotated_children} =
      Enum.reduce(children, {refs, counter, []}, fn child, {acc_refs, acc_c, acc_kids} ->
        {new_refs, new_c, annotated} = walk_and_assign(child, acc_refs, acc_c)
        {new_refs, new_c, [annotated | acc_kids]}
      end)

    node = Map.put(node, "children", Enum.reverse(annotated_children))
    {child_refs, child_counter, node}
  end

  defp walk_and_assign(node, refs, counter) when is_map(node) do
    {counter, refs, node} = maybe_assign_ref(node, refs, counter)
    {refs, counter, node}
  end

  defp walk_and_assign(other, refs, counter), do: {refs, counter, other}

  defp maybe_assign_ref(node, refs, counter) do
    if interactive?(node) do
      ref_id = "e#{counter}"
      center = compute_center(node)
      refs = Map.put(refs, ref_id, center)
      node = Map.put(node, "ref", ref_id)
      {counter + 1, refs, node}
    else
      {counter, refs, node}
    end
  end

  @doc "Check if a node represents an interactive element."
  @spec interactive?(map()) :: boolean()
  def interactive?(%{"role" => role}) when is_binary(role) do
    String.downcase(role) in @interactive_roles
  end

  def interactive?(%{"clickable" => true}), do: true
  def interactive?(%{"focusable" => true}), do: true
  def interactive?(_), do: false

  defp compute_center(%{"bounds" => %{"x" => x, "y" => y, "width" => w, "height" => h}})
       when is_number(x) and is_number(y) and is_number(w) and is_number(h) do
    %{x: round(x + w / 2), y: round(y + h / 2)}
  end

  defp compute_center(%{"position" => %{"x" => x, "y" => y}}), do: %{x: x, y: y}
  defp compute_center(_), do: %{x: 0, y: 0}

  # ---------------------------------------------------------------------------
  # Tree Diffing
  # ---------------------------------------------------------------------------

  @doc """
  Compute the diff between two accessibility trees. Returns a list of changes:
  - `{:added, ref, node}` — new interactive element appeared
  - `{:removed, ref, node}` — interactive element disappeared
  - `{:changed, ref, old_node, new_node}` — element properties changed

  This enables sending only incremental updates to the LLM after each action,
  dramatically reducing token usage.
  """
  @spec diff_trees(ref_map(), ref_map()) :: list()
  def diff_trees(old_refs, new_refs) when is_map(old_refs) and is_map(new_refs) do
    old_keys = MapSet.new(Map.keys(old_refs))
    new_keys = MapSet.new(Map.keys(new_refs))

    added =
      new_keys
      |> MapSet.difference(old_keys)
      |> Enum.map(fn ref -> {:added, ref, Map.get(new_refs, ref)} end)

    removed =
      old_keys
      |> MapSet.difference(new_keys)
      |> Enum.map(fn ref -> {:removed, ref, Map.get(old_refs, ref)} end)

    changed =
      old_keys
      |> MapSet.intersection(new_keys)
      |> Enum.filter(fn ref -> Map.get(old_refs, ref) != Map.get(new_refs, ref) end)
      |> Enum.map(fn ref -> {:changed, ref, Map.get(old_refs, ref), Map.get(new_refs, ref)} end)

    added ++ removed ++ changed
  end

  def diff_trees(_, _), do: []

  # ---------------------------------------------------------------------------
  # Compact Text Formatting (Token-Efficient)
  # ---------------------------------------------------------------------------

  @doc """
  Format an accessibility tree as compact text for LLM consumption.
  Uses ~800 tokens per page vs ~10,000+ for screenshots.

  Output format:
  ```
  [e0] button "Submit" (500,300)
  [e1] textfield "Email" value="user@..." (200,150)
  [e2] link "Home" (100,50)
      [e3] checkbox "Remember me" checked (200,400)
  ```
  """
  @spec format_compact(map(), non_neg_integer()) :: String.t()
  def format_compact(tree, indent_level \\ 0) do
    tree
    |> format_node(indent_level)
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp format_node(%{"children" => children} = node, indent) do
    line = format_single_node(node, indent)
    child_lines = Enum.map(children, fn child -> format_node(child, indent + 1) end)
    [line | child_lines]
  end

  defp format_node(node, indent) when is_map(node) do
    [format_single_node(node, indent)]
  end

  defp format_node(_, _), do: []

  defp format_single_node(node, indent) do
    prefix = String.duplicate("  ", indent)
    role = Map.get(node, "role", "unknown")
    name = Map.get(node, "name")
    value = Map.get(node, "value")
    ref = Map.get(node, "ref")
    states = Map.get(node, "state", [])
    bounds = Map.get(node, "bounds")

    parts = [prefix]
    parts = if ref, do: parts ++ ["[#{ref}] "], else: parts
    parts = parts ++ [role]
    parts = if name && name != "", do: parts ++ [" \"#{truncate(name, 40)}\""], else: parts
    parts = if value && value != "", do: parts ++ [" value=\"#{truncate(value, 20)}\""], else: parts
    parts = if states != [], do: parts ++ [" #{Enum.join(states, ",")}"], else: parts
    parts = if bounds, do: parts ++ [" (#{bounds["x"]},#{bounds["y"]})"], else: parts

    Enum.join(parts)
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."

  # ---------------------------------------------------------------------------
  # Diff Formatting (for incremental updates)
  # ---------------------------------------------------------------------------

  @doc """
  Format a diff as compact text for the LLM.

  Output:
  ```
  + [e5] button "New Button" (300,200)
  - [e2] link "Old Link" (100,50)
  ~ [e1] textfield "Email" moved (200,150) -> (200,180)
  ```
  """
  @spec format_diff(list()) :: String.t()
  def format_diff(changes) do
    changes
    |> Enum.map(&format_change/1)
    |> Enum.join("\n")
  end

  defp format_change({:added, ref, %{x: x, y: y}}) do
    "+ [#{ref}] at (#{x},#{y})"
  end

  defp format_change({:removed, ref, %{x: x, y: y}}) do
    "- [#{ref}] was at (#{x},#{y})"
  end

  defp format_change({:changed, ref, %{x: ox, y: oy}, %{x: nx, y: ny}}) do
    "~ [#{ref}] moved (#{ox},#{oy}) -> (#{nx},#{ny})"
  end

  defp format_change({_, ref, _, _}), do: "? [#{ref}] changed"
  defp format_change({_, ref, _}), do: "? [#{ref}]"

  # ---------------------------------------------------------------------------
  # Platform-specific parsers
  # ---------------------------------------------------------------------------

  @doc """
  Parse macOS AXorcist JSON output into normalized tree format.
  AXorcist returns structured JSON with AX roles and attributes.
  """
  @spec parse_axorcist_output(binary() | map()) :: {:ok, map()} | {:error, String.t()}
  def parse_axorcist_output(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> {:ok, normalize_axorcist(data)}
      {:error, reason} -> {:error, "Failed to parse AXorcist output: #{inspect(reason)}"}
    end
  end

  def parse_axorcist_output(data) when is_map(data) do
    {:ok, normalize_axorcist(data)}
  end

  defp normalize_axorcist(%{"role" => role} = node) do
    children =
      node
      |> Map.get("children", [])
      |> Enum.map(&normalize_axorcist/1)

    %{
      "role" => normalize_role(role),
      "name" => Map.get(node, "title") || Map.get(node, "description") || Map.get(node, "label"),
      "value" => Map.get(node, "value"),
      "bounds" => normalize_bounds(Map.get(node, "frame") || Map.get(node, "position")),
      "state" => extract_states(node),
      "children" => children
    }
  end

  defp normalize_axorcist(%{} = node) do
    %{
      "role" => Map.get(node, "role", "group"),
      "name" => Map.get(node, "title") || Map.get(node, "name"),
      "value" => Map.get(node, "value"),
      "bounds" => nil,
      "state" => [],
      "children" => node |> Map.get("children", []) |> Enum.map(&normalize_axorcist/1)
    }
  end

  defp normalize_axorcist(_) do
    %{
      "role" => "unknown",
      "name" => nil,
      "value" => nil,
      "bounds" => nil,
      "state" => [],
      "children" => []
    }
  end

  @doc """
  Parse Linux AT-SPI2 output into normalized tree format.
  """
  @spec parse_atspi_output(binary()) :: {:ok, map()} | {:error, String.t()}
  def parse_atspi_output(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> {:ok, normalize_atspi(data)}
      {:error, reason} -> {:error, "Failed to parse AT-SPI output: #{inspect(reason)}"}
    end
  end

  defp normalize_atspi(%{"role" => role} = node) do
    children =
      node
      |> Map.get("children", [])
      |> Enum.map(&normalize_atspi/1)

    %{
      "role" => normalize_role(role),
      "name" => Map.get(node, "name") || Map.get(node, "description"),
      "value" => Map.get(node, "value"),
      "bounds" => normalize_bounds(Map.get(node, "extents") || Map.get(node, "bounds")),
      "state" => Map.get(node, "states", []),
      "children" => children
    }
  end

  defp normalize_atspi(node) when is_map(node) do
    %{
      "role" => "group",
      "name" => nil,
      "value" => nil,
      "bounds" => nil,
      "state" => [],
      "children" => node |> Map.get("children", []) |> Enum.map(&normalize_atspi/1)
    }
  end

  defp normalize_atspi(_) do
    %{
      "role" => "unknown",
      "name" => nil,
      "value" => nil,
      "bounds" => nil,
      "state" => [],
      "children" => []
    }
  end

  # Role normalization — map platform-specific roles to common names
  @role_map %{
    # macOS AX roles
    "AXButton" => "button",
    "AXLink" => "link",
    "AXTextField" => "textfield",
    "AXTextArea" => "textarea",
    "AXCheckBox" => "checkbox",
    "AXRadioButton" => "radio",
    "AXMenuItem" => "menuitem",
    "AXTab" => "tab",
    "AXSlider" => "slider",
    "AXComboBox" => "combobox",
    "AXPopUpButton" => "popupbutton",
    "AXWindow" => "window",
    "AXGroup" => "group",
    "AXStaticText" => "text",
    "AXImage" => "image",
    "AXToolbar" => "toolbar",
    "AXMenuBar" => "menubar",
    "AXScrollArea" => "scrollarea",
    "AXTable" => "table",
    "AXRow" => "row",
    "AXCell" => "cell",
    "AXList" => "list",
    "AXOutline" => "outline",
    # AT-SPI roles (already lowercase typically)
    "push button" => "button",
    "toggle button" => "toggle",
    "check box" => "checkbox",
    "radio button" => "radio",
    "text" => "textfield",
    "password text" => "textfield",
    "menu item" => "menuitem",
    "page tab" => "tab",
    "combo box" => "combobox",
    "scroll pane" => "scrollarea",
    "tree table" => "table",
    "table cell" => "cell",
    "list item" => "listitem",
    "tool bar" => "toolbar",
    "menu bar" => "menubar",
    "status bar" => "statusbar"
  }

  defp normalize_role(role) when is_binary(role) do
    Map.get(@role_map, role, String.downcase(role))
  end

  defp normalize_role(_), do: "unknown"

  defp normalize_bounds(%{"x" => x, "y" => y, "width" => w, "height" => h}) do
    %{"x" => round(x), "y" => round(y), "width" => round(w), "height" => round(h)}
  end

  defp normalize_bounds(%{"x" => x, "y" => y, "w" => w, "h" => h}) do
    %{"x" => round(x), "y" => round(y), "width" => round(w), "height" => round(h)}
  end

  defp normalize_bounds(_), do: nil

  defp extract_states(node) do
    []
    |> maybe_add_state(node, "enabled", false, "disabled")
    |> maybe_add_state(node, "focused", true, "focused")
    |> maybe_add_state(node, "selected", true, "selected")
    |> maybe_add_state(node, "checked", true, "checked")
    |> maybe_add_state(node, "expanded", true, "expanded")
    |> maybe_add_state(node, "visible", false, "hidden")
    |> Enum.reverse()
  end

  defp maybe_add_state(states, node, key, trigger_value, label) do
    if Map.get(node, key) == trigger_value, do: [label | states], else: states
  end
end
