defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Server do
  @moduledoc """
  GenServer managing cross-platform computer use.

  Detects the current platform at startup, selects the appropriate adapter
  (macOS, Linux X11, Linux Wayland), and dispatches actions through it.

  Caches the accessibility tree and assigns element refs (e0, e1, e2...)
  for structured element targeting instead of coordinate-based clicking.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  # 10 min idle shutdown
  @idle_timeout_ms 10 * 60 * 1_000

  # State struct
  defstruct [
    :platform,
    :adapter,
    :ax_tree,            # cached accessibility tree
    :element_refs,       # %{"e0" => %{...}, "e1" => %{...}}
    :ax_tree_timestamp,  # when tree was last fetched (monotonic ms)
    :idle_ref
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Execute a computer use action. Returns {:ok, result} | {:error, reason}."
  def execute(action, args \\ %{}) do
    GenServer.call(__MODULE__, {:execute, action, args}, 30_000)
  end

  @doc "Get the current accessibility tree with element refs."
  def get_element_tree(opts \\ %{}) do
    GenServer.call(__MODULE__, {:get_tree, opts}, 15_000)
  end

  @doc "Get current platform info."
  def platform_info do
    GenServer.call(__MODULE__, :platform_info, 5_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    platform = Adapter.detect_platform()

    case Adapter.adapter_for(platform) do
      {:ok, adapter_mod} when is_atom(adapter_mod) ->
        if adapter_mod.available?() do
          Logger.info("[ComputerUse.Server] Platform: #{platform}, Adapter: #{inspect(adapter_mod)}")
          ref = schedule_idle_shutdown()

          {:ok, %__MODULE__{
            platform: platform,
            adapter: adapter_mod,
            ax_tree: nil,
            element_refs: %{},
            ax_tree_timestamp: nil,
            idle_ref: ref
          }}
        else
          Logger.warning("[ComputerUse.Server] Adapter #{inspect(adapter_mod)} not available on this host")
          {:ok, %__MODULE__{
            platform: platform,
            adapter: nil,
            ax_tree: nil,
            element_refs: %{},
            ax_tree_timestamp: nil,
            idle_ref: nil
          }}
        end

      {:error, reason} ->
        Logger.warning("[ComputerUse.Server] No adapter for platform #{platform}: #{reason}")
        {:ok, %__MODULE__{
          platform: platform,
          adapter: nil,
          ax_tree: nil,
          element_refs: %{},
          ax_tree_timestamp: nil,
          idle_ref: nil
        }}
    end
  end

  @impl true
  def handle_call({:execute, _action, _args}, _from, %{adapter: nil} = state) do
    {:reply, {:error, "No computer use adapter available for platform #{state.platform}"}, state}
  end

  def handle_call({:execute, action, args}, _from, state) do
    state = cancel_idle(state)
    result = dispatch_action(action, args, state)
    ref = schedule_idle_shutdown()
    {:reply, result, %{state | idle_ref: ref}}
  end

  def handle_call({:get_tree, _opts}, _from, %{adapter: nil} = state) do
    {:reply, {:error, "No adapter available"}, state}
  end

  def handle_call({:get_tree, opts}, _from, state) do
    state = cancel_idle(state)
    {result, new_state} = fetch_accessibility_tree(opts, state)
    ref = schedule_idle_shutdown()
    {:reply, result, %{new_state | idle_ref: ref}}
  end

  def handle_call(:platform_info, _from, state) do
    info = %{
      platform: state.platform,
      adapter: if(state.adapter, do: state.adapter.platform(), else: nil),
      adapter_available: state.adapter != nil,
      ax_tree_cached: state.ax_tree != nil,
      element_count: map_size(state.element_refs)
    }
    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_info(:idle_shutdown, state) do
    Logger.info("[ComputerUse.Server] Idle timeout — shutting down")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Action dispatch
  # ---------------------------------------------------------------------------

  defp dispatch_action("screenshot", args, state) do
    opts = Map.take(args, ["region"])
    state.adapter.screenshot(opts)
  end

  defp dispatch_action("click", %{"x" => x, "y" => y} = args, state) do
    case Map.get(args, "target") do
      nil -> state.adapter.click(x, y, args)
      ref -> click_element_ref(ref, state)
    end
  end

  defp dispatch_action("click", %{"target" => ref}, state) do
    click_element_ref(ref, state)
  end

  defp dispatch_action("double_click", %{"x" => x, "y" => y}, state) do
    state.adapter.double_click(x, y)
  end

  defp dispatch_action("type", %{"text" => text}, state) do
    state.adapter.type_text(text)
  end

  defp dispatch_action("key", %{"text" => combo}, state) do
    state.adapter.key_press(combo)
  end

  defp dispatch_action("scroll", %{"direction" => dir} = args, state) do
    amount = Map.get(args, "amount", 3)
    state.adapter.scroll(dir, amount)
  end

  defp dispatch_action("move_mouse", %{"x" => x, "y" => y}, state) do
    state.adapter.move_mouse(x, y)
  end

  defp dispatch_action("drag", %{"x" => x, "y" => y} = args, state) do
    {end_x, end_y} =
      case Map.get(args, "region") do
        %{"x" => ex, "y" => ey} -> {ex, ey}
        _ -> {x, y}
      end

    state.adapter.drag(x, y, end_x, end_y)
  end

  defp dispatch_action("get_tree", args, state) do
    case fetch_accessibility_tree(args, state) do
      {{:ok, _tree} = ok, _new_state} -> ok
      {{:error, _} = err, _new_state} -> err
    end
  end

  defp dispatch_action(action, _args, _state) do
    {:error, "Unknown action: #{action}"}
  end

  # ---------------------------------------------------------------------------
  # Element ref targeting
  # ---------------------------------------------------------------------------

  defp click_element_ref(ref, state) do
    case Map.get(state.element_refs, ref) do
      %{"x" => x, "y" => y} ->
        state.adapter.click(x, y, %{})

      nil ->
        {:error,
         "Element ref '#{ref}' not found. Use get_tree action to refresh the accessibility tree."}
    end
  end

  # ---------------------------------------------------------------------------
  # Accessibility tree
  # ---------------------------------------------------------------------------

  # Cache TTL: 5 seconds
  @tree_ttl_ms 5_000

  defp fetch_accessibility_tree(opts, state) do
    cached? =
      state.ax_tree != nil &&
        state.ax_tree_timestamp != nil &&
        System.monotonic_time(:millisecond) - state.ax_tree_timestamp < @tree_ttl_ms &&
        not Map.get(opts, "force_refresh", false)

    if cached? do
      {{:ok, format_tree_response(state)}, state}
    else
      case state.adapter.get_accessibility_tree(opts) do
        {:ok, tree} ->
          {refs, indexed_tree} = assign_element_refs(tree)

          new_state = %{state |
            ax_tree: indexed_tree,
            element_refs: refs,
            ax_tree_timestamp: System.monotonic_time(:millisecond)
          }

          {{:ok, format_tree_response(new_state)}, new_state}

        {:error, _} = err ->
          {err, state}
      end
    end
  end

  defp assign_element_refs(tree) when is_map(tree) do
    {refs, _counter, indexed} = walk_tree(tree, %{}, 0)
    {refs, indexed}
  end

  defp assign_element_refs(_), do: {%{}, %{}}

  # Node with children: walk children, then tag node itself if interactive.
  defp walk_tree(%{"children" => children} = node, refs, counter) do
    # First walk all children
    {refs_after_children, counter_after_children, indexed_children} =
      Enum.reduce(children, {refs, counter, []}, fn child, {acc_refs, acc_counter, acc_children} ->
        {new_refs, new_counter, indexed_child} = walk_tree(child, acc_refs, acc_counter)
        {new_refs, new_counter, acc_children ++ [indexed_child]}
      end)

    node_with_children = Map.put(node, "children", indexed_children)

    # Tag the node itself if interactive
    if interactive?(node_with_children) do
      ref_id = "e#{counter_after_children}"
      center = element_center(node_with_children)
      final_refs = Map.put(refs_after_children, ref_id, center)
      tagged_node = Map.put(node_with_children, "ref", ref_id)
      {final_refs, counter_after_children + 1, tagged_node}
    else
      {refs_after_children, counter_after_children, node_with_children}
    end
  end

  # Leaf node: tag if interactive.
  defp walk_tree(node, refs, counter) when is_map(node) do
    if interactive?(node) do
      ref_id = "e#{counter}"
      center = element_center(node)
      final_refs = Map.put(refs, ref_id, center)
      tagged_node = Map.put(node, "ref", ref_id)
      {final_refs, counter + 1, tagged_node}
    else
      {refs, counter, node}
    end
  end

  defp walk_tree(node, refs, counter), do: {refs, counter, node}

  defp interactive?(%{"role" => role})
       when role in ~w(button link textfield checkbox radio menuitem tab slider) do
    true
  end

  defp interactive?(%{"clickable" => true}), do: true
  defp interactive?(_), do: false

  defp element_center(%{"bounds" => %{"x" => x, "y" => y, "width" => w, "height" => h}}) do
    %{"x" => x + div(w, 2), "y" => y + div(h, 2)}
  end

  defp element_center(%{"x" => x, "y" => y}), do: %{"x" => x, "y" => y}
  defp element_center(_), do: %{"x" => 0, "y" => 0}

  defp format_tree_response(state) do
    %{
      "platform" => to_string(state.platform),
      "element_count" => map_size(state.element_refs),
      "elements" => state.element_refs,
      "tree" => state.ax_tree,
      "hint" =>
        "Use 'target' parameter with element refs (e0, e1...) for reliable clicking instead of coordinates."
    }
  end

  # ---------------------------------------------------------------------------
  # Idle management
  # ---------------------------------------------------------------------------

  defp schedule_idle_shutdown do
    Process.send_after(self(), :idle_shutdown, @idle_timeout_ms)
  end

  defp cancel_idle(%{idle_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | idle_ref: nil}
  end

  defp cancel_idle(state), do: state
end
