defmodule OptimalSystemAgent.Agent.Orchestrator.ComplexityTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Orchestrator.Complexity

  # ── quick_check/1 ─────────────────────────────────────────────────

  describe "quick_check/1" do
    test "short simple messages return :likely_simple" do
      assert Complexity.quick_check("fix the typo") == :likely_simple
      assert Complexity.quick_check("add a button") == :likely_simple
    end

    test "long messages return :possibly_complex" do
      long = String.duplicate("refactor the authentication system ", 30)
      assert Complexity.quick_check(long) == :possibly_complex
    end

    test "multi-task patterns with sufficient length return :possibly_complex" do
      msg = "Please refactor the authentication module and also update the database schema with all the new columns for user preferences and session tracking. Additionally, we need to migrate the API endpoints to the new format including versioning and backwards compatibility layers. Then also update all the integration tests to match the new behavior and ensure full coverage of the edge cases including concurrent access patterns and error recovery scenarios. Furthermore, the deployment pipeline needs updating to handle the new database migration steps properly."
      assert Complexity.quick_check(msg) == :possibly_complex
    end
  end

  # ── parse_response/1 — new return shapes ──────────────────────────

  describe "parse_response/1" do
    test "simple response returns {:simple, score}" do
      json = Jason.encode!(%{
        "complexity" => "simple",
        "complexity_score" => 2,
        "reasoning" => "straightforward"
      })

      assert {:simple, 2} = Complexity.parse_response(json)
    end

    test "simple response without score defaults to 3" do
      json = Jason.encode!(%{"complexity" => "simple", "reasoning" => "easy"})
      assert {:simple, 3} = Complexity.parse_response(json)
    end

    test "complex response returns {:complex, score, sub_tasks}" do
      json = Jason.encode!(%{
        "complexity" => "complex",
        "complexity_score" => 7,
        "reasoning" => "multi-system",
        "sub_tasks" => [
          %{
            "name" => "schema_design",
            "description" => "Design the database schema",
            "role" => "data",
            "tools_needed" => ["file_read"],
            "depends_on" => []
          },
          %{
            "name" => "api_handlers",
            "description" => "Build API endpoints",
            "role" => "backend",
            "tools_needed" => ["file_read", "file_write"],
            "depends_on" => ["schema_design"]
          }
        ]
      })

      assert {:complex, 7, sub_tasks} = Complexity.parse_response(json)
      assert length(sub_tasks) == 2
      assert hd(sub_tasks).name == "schema_design"
      assert hd(sub_tasks).role == :data
    end

    test "complex response without score defaults to 6" do
      json = Jason.encode!(%{
        "complexity" => "complex",
        "reasoning" => "needs work",
        "sub_tasks" => [
          %{"name" => "task1", "description" => "do stuff", "role" => "backend", "tools_needed" => [], "depends_on" => []}
        ]
      })

      assert {:complex, 6, _} = Complexity.parse_response(json)
    end

    test "invalid JSON returns {:simple, 3}" do
      assert {:simple, 3} = Complexity.parse_response("not json at all")
    end

    test "unexpected format returns {:simple, 3}" do
      json = Jason.encode!(%{"something" => "else"})
      assert {:simple, 3} = Complexity.parse_response(json)
    end

    test "handles markdown-fenced JSON" do
      json = "```json\n#{Jason.encode!(%{"complexity" => "simple", "complexity_score" => 4, "reasoning" => "ok"})}\n```"
      assert {:simple, 4} = Complexity.parse_response(json)
    end

    test "complexity_score out of range defaults" do
      json = Jason.encode!(%{"complexity" => "simple", "complexity_score" => 0})
      assert {:simple, 3} = Complexity.parse_response(json)

      json2 = Jason.encode!(%{"complexity" => "simple", "complexity_score" => 11})
      assert {:simple, 3} = Complexity.parse_response(json2)
    end

    test "parses all 9 roles correctly" do
      roles = ~w(lead backend frontend data design infra qa red_team services)

      for role <- roles do
        json = Jason.encode!(%{
          "complexity" => "complex",
          "complexity_score" => 5,
          "sub_tasks" => [%{"name" => "t", "description" => "d", "role" => role, "tools_needed" => [], "depends_on" => []}]
        })

        assert {:complex, 5, [task]} = Complexity.parse_response(json)
        assert is_atom(task.role)
      end
    end
  end

  # ── parse_role/1 ──────────────────────────────────────────────────

  describe "parse_role/1" do
    test "maps all 9 dispatch roles" do
      assert Complexity.parse_role("lead") == :lead
      assert Complexity.parse_role("backend") == :backend
      assert Complexity.parse_role("frontend") == :frontend
      assert Complexity.parse_role("data") == :data
      assert Complexity.parse_role("design") == :design
      assert Complexity.parse_role("infra") == :infra
      assert Complexity.parse_role("qa") == :qa
      assert Complexity.parse_role("red_team") == :red_team
      assert Complexity.parse_role("services") == :services
    end

    test "maps legacy aliases" do
      assert Complexity.parse_role("researcher") == :data
      assert Complexity.parse_role("builder") == :backend
      assert Complexity.parse_role("tester") == :qa
      assert Complexity.parse_role("reviewer") == :red_team
      assert Complexity.parse_role("writer") == :lead
    end

    test "unknown role defaults to :backend" do
      assert Complexity.parse_role("nonexistent") == :backend
      assert Complexity.parse_role("") == :backend
    end
  end
end
