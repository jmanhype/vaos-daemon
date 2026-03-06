defmodule OptimalSystemAgent.Commands.Dev do
  @moduledoc """
  Development workflow commands — autofix, recipes, and automation.
  """

  alias OptimalSystemAgent.Agent.AutoFixer
  alias OptimalSystemAgent.Recipes.Recipe

  @doc """
  Run auto-fix loop for tests, lint, or compile errors.

  Usage:
    /autofix                — detect and run appropriate fix loop
    /autofix test           — fix failing tests
    /autofix lint           — fix lint errors
    /autofix compile        — fix compile errors
    /autofix typecheck      — fix type errors
    /autofix test --stale   — only run stale/changed tests
    /autofix --async        — run in background, return immediately
  """
  def cmd_autofix(arg, session_id) do
    {type, opts} = parse_autofix_args(arg)

    autofix_opts = %{
      type: type,
      session_id: session_id,
      max_iterations: 5,
      stale_only: opts[:stale] || false
    }

    if opts[:async] do
      case AutoFixer.run_async(autofix_opts) do
        {:ok, _task} ->
          {:command, "⏳ AutoFixer started in background for #{type}#{if opts[:stale], do: " (stale only)", else: ""}"}

        {:error, reason} ->
          {:command, "✗ AutoFixer error: #{reason}"}
      end
    else
      run_autofix_sync(type, autofix_opts, opts)
    end
  end

  defp run_autofix_sync(type, autofix_opts, opts) do
    stale_note = if opts[:stale], do: " (stale only)", else: ""

    case AutoFixer.run(autofix_opts) do
      {:ok, %{success: true, iterations: n, fixes_applied: fixes}} ->
        summary =
          if fixes == [] do
            "All checks passed on first run."
          else
            "Fixed in #{n} iteration(s):\n" <>
              Enum.map_join(fixes, "\n", fn f -> "  • #{String.slice(f, 0, 100)}" end)
          end

        {:command, "✓ #{type}#{stale_note} passed\n\n#{summary}"}

      {:ok, %{success: false, iterations: n, remaining_errors: errors}} ->
        error_preview = Enum.take(errors, 5) |> Enum.join("\n")

        {:command,
         "✗ #{type}#{stale_note} failed after #{n} iterations\n\nRemaining errors:\n```\n#{error_preview}\n```"}

      {:error, reason} ->
        {:command, "✗ AutoFixer error: #{reason}"}
    end
  end

  defp parse_autofix_args(arg) do
    parts = String.split(arg)

    opts = %{
      stale: "--stale" in parts or "-s" in parts,
      async: "--async" in parts or "-a" in parts
    }

    # Filter out flags to get the type
    type_parts = Enum.reject(parts, &String.starts_with?(&1, "-"))
    type = parse_fix_type(Enum.join(type_parts, " "))

    {type, opts}
  end

  @doc """
  List and run recipes/workflows.

  Usage:
    /recipe                  — list available recipes
    /recipe code-review      — run the code-review recipe
    /recipe <name> <context> — run recipe with additional context
  """
  def cmd_recipe(arg, session_id) do
    args = String.split(arg, " ", parts: 2)

    case args do
      [""] ->
        list_recipes()

      ["list"] ->
        list_recipes()

      [name] ->
        run_recipe(name, "", session_id)

      [name, context] ->
        run_recipe(name, context, session_id)

      _ ->
        list_recipes()
    end
  end

  @doc """
  Create a new recipe interactively.

  Usage:
    /recipe-create <name> — create a new recipe with the given name
  """
  def cmd_recipe_create(arg, _session_id) do
    name = String.trim(arg)

    if name == "" do
      {:command, "Usage: /recipe-create <name>\n\nExample: /recipe-create security-audit"}
    else
      # Create a starter recipe
      steps = [
        %{
          name: "Step 1",
          description: "Describe what this step should do",
          signal_mode: "ANALYZE",
          tools_needed: ["file_read"],
          acceptance_criteria: "Define when this step is complete"
        }
      ]

      case Recipe.create(name, "Describe what this recipe does", steps) do
        {:ok, path} ->
          {:command, "✓ Created recipe at: #{path}\n\nEdit the JSON to add your steps."}

        {:error, reason} ->
          {:command, "✗ Failed to create recipe: #{reason}"}
      end
    end
  end

  # ── Private ────────────────────────────────────────────────────

  defp parse_fix_type(arg) do
    case String.trim(arg) |> String.downcase() do
      "" -> :test
      "test" -> :test
      "tests" -> :test
      "lint" -> :lint
      "linter" -> :lint
      "compile" -> :compile
      "build" -> :compile
      "typecheck" -> :typecheck
      "types" -> :typecheck
      _ -> :test
    end
  end

  defp list_recipes do
    recipes = Recipe.list()

    if recipes == [] do
      {:command,
       "No recipes found.\n\nCreate one with /recipe-create <name>\n\nOr add JSON files to:\n  • ~/.osa/recipes/\n  • .osa/recipes/"}
    else
      lines =
        Enum.map_join(recipes, "\n", fn r ->
          "  /recipe #{r.slug}  — #{r.description} (#{r.steps} steps)"
        end)

      {:command, "Available recipes:\n\n#{lines}\n\nRun with: /recipe <name>"}
    end
  end

  defp run_recipe(name, context, _session_id) do
    case Recipe.load(name) do
      {:ok, recipe} ->
        # One concise line per step — keeps prompt well under 150 tokens
        steps_desc = Enum.map_join(recipe.steps, ", ", & &1.name)

        context_section = if context != "", do: " Context: #{context}.", else: ""

        prompt =
          "Run recipe: #{recipe.name}.#{context_section} " <>
            "Steps in order: #{steps_desc}. Start with step 1."

        {:new_session_prompt, prompt}

      {:error, reason} ->
        {:command, "✗ #{reason}"}
    end
  end
end
