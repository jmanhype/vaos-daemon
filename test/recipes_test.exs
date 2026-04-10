defmodule Daemon.RecipesTest do
  use ExUnit.Case, async: true

  alias Daemon.Recipes.Recipe

  # ---------------------------------------------------------------------------
  # Module smoke tests
  # ---------------------------------------------------------------------------

  describe "module definition" do
    test "Recipe module is defined and loaded" do
      assert Code.ensure_loaded?(Recipe)
    end

    test "exports list/0" do
      assert Code.ensure_loaded?(Recipe)
      assert function_exported?(Recipe, :list, 0)
    end

    test "exports load/1" do
      assert Code.ensure_loaded?(Recipe)
      assert function_exported?(Recipe, :load, 1)
    end

    test "exports load_file/1" do
      assert Code.ensure_loaded?(Recipe)
      assert function_exported?(Recipe, :load_file, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # list/0
  # ---------------------------------------------------------------------------

  describe "list/0" do
    test "returns a list of recipe maps" do
      recipes = Recipe.list()
      assert is_list(recipes)
      assert length(recipes) >= 12
    end

    test "each recipe has required fields" do
      Recipe.list()
      |> Enum.each(fn r ->
        assert Map.has_key?(r, :name)
        assert Map.has_key?(r, :slug)
        assert Map.has_key?(r, :description)
        assert Map.has_key?(r, :steps)
        assert is_integer(r.steps) and r.steps > 0
      end)
    end

    test "code-review recipe is present" do
      slugs = Recipe.list() |> Enum.map(& &1.slug)
      assert "code-review" in slugs
    end
  end

  # ---------------------------------------------------------------------------
  # load/1
  # ---------------------------------------------------------------------------

  describe "load/1" do
    test "loads code-review recipe successfully" do
      assert {:ok, recipe} = Recipe.load("code-review")
      assert recipe.name == "Code Review"
      assert is_list(recipe.steps)
      assert length(recipe.steps) == 5
    end

    test "each step has name, description, signal_mode" do
      {:ok, recipe} = Recipe.load("code-review")

      Enum.each(recipe.steps, fn step ->
        assert is_binary(step.name)
        assert is_binary(step.description)
        assert is_binary(step.signal_mode)
      end)
    end

    test "returns error for nonexistent recipe" do
      assert {:error, msg} = Recipe.load("zzz-nonexistent-recipe-xyz")
      assert msg =~ "not found"
    end

    test "loads all 12 canonical recipes" do
      slugs = ~w(
        add-feature build-fullstack-app build-rest-api code-review
        content-campaign debug-production-issue migrate-database
        onboard-developer performance-optimization refactor
        security-audit write-docs
      )

      for slug <- slugs do
        assert {:ok, recipe} = Recipe.load(slug), "Failed to load recipe: #{slug}"
        assert is_list(recipe.steps) and length(recipe.steps) > 0
      end
    end
  end

  # ---------------------------------------------------------------------------
  # load_file/1 — JSON validation
  # ---------------------------------------------------------------------------

  describe "load_file/1 validation" do
    setup do
      dir = System.tmp_dir!() |> Path.join("osa_recipe_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "rejects JSON missing 'name'", %{dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, Jason.encode!(%{"description" => "x", "steps" => [%{"name" => "s1", "description" => "d1"}]}))
      assert {:error, msg} = Recipe.load_file(path)
      assert msg =~ "name"
    end

    test "rejects JSON missing 'description'", %{dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, Jason.encode!(%{"name" => "X", "steps" => [%{"name" => "s1", "description" => "d1"}]}))
      assert {:error, msg} = Recipe.load_file(path)
      assert msg =~ "description"
    end

    test "rejects JSON missing 'steps'", %{dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, Jason.encode!(%{"name" => "X", "description" => "x"}))
      assert {:error, msg} = Recipe.load_file(path)
      assert msg =~ "steps"
    end

    test "rejects empty steps array", %{dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, Jason.encode!(%{"name" => "X", "description" => "x", "steps" => []}))
      assert {:error, msg} = Recipe.load_file(path)
      assert msg =~ "at least one step"
    end

    test "rejects step missing 'name'", %{dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, Jason.encode!(%{"name" => "X", "description" => "x", "steps" => [%{"description" => "d"}]}))
      assert {:error, msg} = Recipe.load_file(path)
      assert msg =~ "name"
    end

    test "rejects step missing 'description'", %{dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, Jason.encode!(%{"name" => "X", "description" => "x", "steps" => [%{"name" => "s"}]}))
      assert {:error, msg} = Recipe.load_file(path)
      assert msg =~ "description"
    end

    test "rejects non-object at root", %{dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, "[1,2,3]")
      assert {:error, msg} = Recipe.load_file(path)
      assert msg =~ "JSON object"
    end

    test "accepts valid minimal recipe", %{dir: dir} do
      path = Path.join(dir, "good.json")

      recipe = %{
        "name" => "Test Recipe",
        "description" => "A test",
        "steps" => [
          %{"name" => "Step 1", "description" => "Do thing"}
        ]
      }

      File.write!(path, Jason.encode!(recipe))
      assert {:ok, loaded} = Recipe.load_file(path)
      assert loaded.name == "Test Recipe"
      assert length(loaded.steps) == 1
      assert hd(loaded.steps).signal_mode == "ANALYZE"
    end

    test "rejects invalid JSON syntax", %{dir: dir} do
      path = Path.join(dir, "bad.json")
      File.write!(path, "{not valid json!!}")
      assert {:error, msg} = Recipe.load_file(path)
      assert msg =~ "Invalid JSON"
    end

    test "returns error for missing file" do
      assert {:error, msg} = Recipe.load_file("/tmp/osa_no_such_file_ever.json")
      assert msg =~ "Failed to read"
    end
  end

  # ---------------------------------------------------------------------------
  # /recipe command — new_session_prompt flow
  # ---------------------------------------------------------------------------

  describe "recipe command via Commands.execute/2" do
    test "/recipe with no arg lists available recipes" do
      result = Daemon.Commands.execute("recipe", "test-session")
      assert {:command, output} = result
      assert output =~ "recipe"
    end

    test "/recipe code-review returns {:new_session_prompt, _}" do
      result = Daemon.Commands.execute("recipe code-review", "test-session")
      assert {:new_session_prompt, prompt} = result
      assert is_binary(prompt)
      assert prompt =~ "Code Review"
      assert prompt =~ "Start with step 1"
    end

    test "/recipe nonexistent returns {:command, error}" do
      result = Daemon.Commands.execute("recipe zzz-no-such", "test-session")
      assert {:command, output} = result
      assert output =~ "✗"
    end

    test "new_session_prompt prompt is compact (under 200 chars)" do
      {:new_session_prompt, prompt} =
        Daemon.Commands.execute("recipe code-review", "test-session")

      assert String.length(prompt) < 200,
             "Prompt too long (#{String.length(prompt)} chars): #{prompt}"
    end
  end
end
