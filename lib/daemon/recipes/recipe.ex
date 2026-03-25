defmodule Daemon.Recipes.Recipe do
  @moduledoc """
  Recipe/Workflow system for multi-step guided tasks.

  Recipes are JSON files defining a sequence of steps with:
  - Name and description
  - Signal mode for each step (ANALYZE, IMPLEMENT, ASSIST)
  - Required tools
  - Acceptance criteria

  ## Recipe Format (JSON)

      {
        "name": "Code Review",
        "description": "Systematic code review workflow",
        "steps": [
          {
            "name": "Understand Changes",
            "description": "Read and understand the diff",
            "signal_mode": "ANALYZE",
            "tools_needed": ["file_read", "shell_execute"],
            "acceptance_criteria": "Changes understood"
          }
        ]
      }

  ## Usage

      # Load and run a recipe
      {:ok, recipe} = Recipe.load("code-review")
      {:ok, result} = Recipe.run(recipe, %{session_id: "abc", context: context})

      # List available recipes
      Recipe.list()

  ## Recipe Resolution

  Recipes are resolved in order:
  1. Custom recipes in `~/.daemon/recipes/`
  2. Project recipes in `.daemon/recipes/`
  3. Built-in recipes in `priv/recipes/`
  4. Examples fallback in `examples/workflows/`
  """

  require Logger

  alias MiosaProviders.Registry, as: Providers
  alias Daemon.Tools.Registry, as: Tools
  alias Daemon.Workspace
  alias Daemon.Events.Bus

  @type step :: %{
          name: String.t(),
          description: String.t(),
          signal_mode: String.t(),
          tools_needed: [String.t()],
          acceptance_criteria: String.t()
        }

  @type recipe :: %{
          name: String.t(),
          description: String.t(),
          steps: [step()],
          source: String.t()
        }

  @type run_result :: %{
          success: boolean(),
          steps_completed: non_neg_integer(),
          total_steps: non_neg_integer(),
          step_results: [map()],
          error: String.t() | nil
        }

  @type run_opts :: %{
          required(:session_id) => String.t(),
          optional(:context) => String.t(),
          optional(:cwd) => String.t(),
          optional(:on_step_complete) => (map() -> any())
        }

  # ── Resolution Paths ───────────────────────────────────────────────

  defp recipe_paths do
    [
      # User custom recipes
      Path.expand("~/.daemon/recipes"),
      # Project-local recipes
      Path.join(Workspace.get_cwd(), ".daemon/recipes"),
      # Built-in recipes
      Path.join(:code.priv_dir(:daemon), "recipes"),
      # Examples (fallback)
      case File.cwd() do
        {:ok, cwd} -> Path.join(cwd, "examples/workflows")
        _ -> "examples/workflows"
      end
    ]
  end

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  List all available recipes.
  """
  @spec list() :: [%{name: String.t(), description: String.t(), source: String.t()}]
  def list do
    recipe_paths()
    |> Enum.flat_map(fn path ->
      if File.dir?(path) do
        (case File.ls(path) do {:ok, files} -> files; _ -> [] end)
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(fn file ->
          full_path = Path.join(path, file)
          
          case load_file(full_path) do
            {:ok, recipe} ->
              %{
                name: recipe.name,
                slug: Path.basename(file, ".json"),
                description: recipe.description,
                source: path,
                steps: length(recipe.steps)
              }

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      else
        []
      end
    end)
    |> Enum.uniq_by(& &1.slug)
  end

  @doc """
  Load a recipe by name/slug.

  Searches in resolution order and returns first match.
  """
  @spec load(String.t()) :: {:ok, recipe()} | {:error, String.t()}
  def load(name) do
    # Strict slug sanitization — strip everything except alphanumeric and hyphens
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9\-]+/, "")
    filename = "#{slug}.json"

    result =
      recipe_paths()
      |> Enum.find_value(fn path ->
        full_path = Path.join(path, filename)

        if File.exists?(full_path) do
          case load_file(full_path) do
            {:ok, recipe} -> {:ok, %{recipe | source: path}}
            error -> error
          end
        else
          nil
        end
      end)

    case result do
      nil -> {:error, "Recipe '#{name}' not found in: #{Enum.join(recipe_paths(), ", ")}"}
      {:ok, recipe} -> {:ok, recipe}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Load and validate a recipe from a file path."
  @spec load_file(String.t()) :: {:ok, recipe()} | {:error, String.t()}
  def load_file(path) do
    expanded = Path.expand(path)
    # Reject paths containing traversal segments
    if String.contains?(expanded, "..") do
      {:error, "Rejected: path contains traversal segments"}
    else
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} ->
              validate_recipe(data, path)

            {:error, reason} ->
              {:error, "Invalid JSON in #{path}: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Failed to read #{path}: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Run a recipe with the given options.
  """
  @spec run(recipe(), run_opts()) :: {:ok, run_result()} | {:error, String.t()}
  def run(recipe, opts) do
    session_id = opts[:session_id]
    context = opts[:context] || ""
    cwd = opts[:cwd] || Workspace.get_cwd()
    on_step_complete = opts[:on_step_complete]

    # Set workspace
    Workspace.set_agent_cwd(cwd)

    Bus.emit(:system_event, %{
      event: :recipe_started,
      session_id: session_id,
      recipe: recipe.name,
      total_steps: length(recipe.steps)
    })

    state = %{
      recipe: recipe,
      session_id: session_id,
      context: context,
      cwd: cwd,
      step_index: 0,
      step_results: [],
      on_step_complete: on_step_complete
    }

    result = run_steps(state)

    Workspace.clear_agent_cwd()

    result
  end

  @doc """
  Create a new recipe from a template.
  """
  @spec create(String.t(), String.t(), [step()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def create(name, description, steps, opts \\ []) do
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
    
    target_dir = opts[:target_dir] || Path.join(Workspace.get_cwd(), ".daemon/recipes")
    File.mkdir_p!(target_dir)
    
    path = Path.join(target_dir, "#{slug}.json")

    recipe = %{
      "name" => name,
      "description" => description,
      "steps" =>
        Enum.map(steps, fn step ->
          %{
            "name" => step[:name] || step["name"],
            "description" => step[:description] || step["description"],
            "signal_mode" => step[:signal_mode] || step["signal_mode"] || "ANALYZE",
            "tools_needed" => step[:tools_needed] || step["tools_needed"] || [],
            "acceptance_criteria" => step[:acceptance_criteria] || step["acceptance_criteria"] || ""
          }
        end)
    }

    content = Jason.encode!(recipe, pretty: true)

    case File.write(path, content) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "Failed to write recipe: #{inspect(reason)}"}
    end
  end

  # ── Private Functions ──────────────────────────────────────────────

  defp validate_recipe(data, path) when is_map(data) do
    with {:ok, name} <- get_required(data, "name", path),
         {:ok, description} <- get_required(data, "description", path),
         {:ok, steps} <- get_required(data, "steps", path),
         :ok <- validate_steps(steps, path) do
      {:ok,
       %{
         name: name,
         description: description,
         steps:
           Enum.map(steps, fn s ->
             %{
               name: s["name"],
               description: s["description"],
               signal_mode: s["signal_mode"] || "ANALYZE",
               tools_needed: s["tools_needed"] || [],
               acceptance_criteria: s["acceptance_criteria"] || ""
             }
           end),
         source: Path.dirname(path)
       }}
    end
  end

  defp validate_recipe(_, path) do
    {:error, "Recipe at #{path} must be a JSON object"}
  end

  defp get_required(data, key, path) do
    case Map.fetch(data, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, "Missing required field '#{key}' in #{path}"}
    end
  end

  defp validate_steps(steps, path) when is_list(steps) do
    cond do
      steps == [] ->
        {:error, "Recipe at #{path} must have at least one step"}

      not Enum.all?(steps, &is_map/1) ->
        {:error, "Steps in #{path} must be objects"}

      not Enum.all?(steps, &Map.has_key?(&1, "name")) ->
        {:error, "Each step in #{path} must have a 'name' field"}

      not Enum.all?(steps, &Map.has_key?(&1, "description")) ->
        {:error, "Each step in #{path} must have a 'description' field"}

      true ->
        :ok
    end
  end

  defp validate_steps(_, path) do
    {:error, "Steps in #{path} must be an array"}
  end

  defp run_steps(%{step_index: i, recipe: recipe} = state) when i >= length(recipe.steps) do
    Bus.emit(:system_event, %{
      event: :recipe_completed,
      session_id: state.session_id,
      recipe: recipe.name,
      success: true,
      steps_completed: length(recipe.steps)
    })

    {:ok,
     %{
       success: true,
       steps_completed: length(recipe.steps),
       total_steps: length(recipe.steps),
       step_results: Enum.reverse(state.step_results),
       error: nil
     }}
  end

  defp run_steps(state) do
    step = Enum.at(state.recipe.steps, state.step_index)

    Logger.info("[Recipe] Running step #{state.step_index + 1}/#{length(state.recipe.steps)}: #{step.name}")

    Bus.emit(:system_event, %{
      event: :recipe_step_started,
      session_id: state.session_id,
      recipe: state.recipe.name,
      step_index: state.step_index,
      step_name: step.name
    })

    case run_step(step, state) do
      {:ok, result} ->
        if state.on_step_complete do
          state.on_step_complete.(%{
            step_index: state.step_index,
            step_name: step.name,
            result: result
          })
        end

        Bus.emit(:system_event, %{
          event: :recipe_step_completed,
          session_id: state.session_id,
          step_index: state.step_index,
          step_name: step.name,
          success: true
        })

        state = %{
          state
          | step_index: state.step_index + 1,
            step_results: [%{step: step.name, success: true, output: result} | state.step_results]
        }

        run_steps(state)

      {:error, reason} ->
        Bus.emit(:system_event, %{
          event: :recipe_step_failed,
          session_id: state.session_id,
          step_index: state.step_index,
          step_name: step.name,
          error: reason
        })

        {:ok,
         %{
           success: false,
           steps_completed: state.step_index,
           total_steps: length(state.recipe.steps),
           step_results: Enum.reverse([%{step: step.name, success: false, error: reason} | state.step_results]),
           error: "Step '#{step.name}' failed: #{reason}"
         }}
    end
  end

  defp run_step(step, state) do
    # Build tools list from step requirements
    all_tools = Tools.list_tools_direct()


    step_tools =
      if step.tools_needed == [] do
        all_tools
      else
        Enum.filter(all_tools, fn t -> t.name in step.tools_needed end)
      end

    # Build prompt for this step
    prompt = build_step_prompt(step, state)

    messages = [
      %{role: "system", content: step_system_prompt(step, state.recipe)},
      %{role: "user", content: prompt}
    ]

    # Run agent loop for this step
    run_step_agent(messages, step_tools, state.cwd, 0, 15)
  end

  defp build_step_prompt(step, state) do
    context_section =
      if state.context != "" do
        """
        ## Context
        #{state.context}

        """
      else
        ""
      end

    prev_results =
      if state.step_results != [] do
        results =
          state.step_results
          |> Enum.map(fn r -> "- **#{r.step}**: #{String.slice(r.output || "", 0, 200)}" end)
          |> Enum.join("\n")

        """
        ## Previous Steps
        #{results}

        """
      else
        ""
      end

    """
    #{context_section}#{prev_results}## Current Step: #{step.name}

    #{step.description}

    ### Acceptance Criteria
    #{step.acceptance_criteria}

    Complete this step thoroughly before indicating you're done.
    """
  end

  defp step_system_prompt(step, recipe) do
    mode_instruction =
      case step.signal_mode do
        "ANALYZE" ->
          "Your mode is ANALYZE. Focus on understanding and examining. Don't make changes, just investigate and report findings."

        "IMPLEMENT" ->
          "Your mode is IMPLEMENT. Focus on making changes, writing code, and executing tasks."

        "ASSIST" ->
          "Your mode is ASSIST. Focus on helping and guiding. Provide explanations and recommendations."

        _ ->
          "Complete the task as requested."
      end

    """
    You are executing step #{step.name} of the "#{recipe.name}" workflow.

    #{mode_instruction}

    Workflow: #{recipe.description}

    Step requirements:
    - Description: #{step.description}
    - Acceptance criteria: #{step.acceptance_criteria}

    Use the available tools to complete this step. When done, provide a clear summary of what you accomplished.
    """
  end

  defp run_step_agent(_messages, _tools, _cwd, iteration, max_iters) when iteration >= max_iters do
    {:error, "Step agent hit max iterations"}
  end

  defp run_step_agent(messages, tools, cwd, iteration, max_iters) do
    Workspace.set_agent_cwd(cwd)

    case Providers.chat(messages, tools: tools, temperature: 0.3, max_tokens: 4000) do
      {:ok, %{content: content, tool_calls: []}} ->
        {:ok, content}

      {:ok, %{content: content, tool_calls: tool_calls}} when is_list(tool_calls) and tool_calls != [] ->
        messages = messages ++ [%{role: "assistant", content: content, tool_calls: tool_calls}]

        messages =
          Enum.reduce(tool_calls, messages, fn tool_call, msgs ->
            result =
              case Tools.execute_direct(tool_call.name, tool_call.arguments) do
                {:ok, output} -> output
                {:error, reason} -> "Error: #{reason}"
              end

            msgs ++ [%{role: "tool", tool_call_id: tool_call.id, content: result}]
          end)

        run_step_agent(messages, tools, cwd, iteration + 1, max_iters)

      {:ok, %{content: content}} when is_binary(content) ->
        {:ok, content}

      {:error, reason} ->
        {:error, "LLM error: #{inspect(reason)}"}
    end
  end
end
