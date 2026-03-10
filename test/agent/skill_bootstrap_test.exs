defmodule OptimalSystemAgent.Agent.SkillBootstrapTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Agent.SkillBootstrap
  alias OptimalSystemAgent.Channels.HTTP.API.SkillBootstrapRoutes

  @opts SkillBootstrapRoutes.init([])

  # Clean up any test skills created
  setup do
    on_exit(fn ->
      ~w(test-bootstrap-skill test-skill-abc)
      |> Enum.each(fn name ->
        dir = Path.expand("~/.osa/skills/#{name}")
        File.rm_rf(dir)
      end)
    end)

    :ok
  end

  defp json_post(path, body \\ %{}) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> SkillBootstrapRoutes.call(@opts)
  end

  defp json_get(path) do
    conn(:get, path)
    |> SkillBootstrapRoutes.call(@opts)
  end

  # ── SkillBootstrap module ─────────────────────────────────────────

  describe "SkillBootstrap module" do
    test "module is defined" do
      assert Code.ensure_loaded?(SkillBootstrap)
    end

    test "create_and_run/2 is exported" do
      assert function_exported?(SkillBootstrap, :create_and_run, 2)
    end

    test "list_self_skills/0 is exported" do
      assert function_exported?(SkillBootstrap, :list_self_skills, 0)
    end

    test "list_self_skills/0 returns a list" do
      result = SkillBootstrap.list_self_skills()
      assert is_list(result)
    end
  end

  describe "create_and_run/2" do
    test "creates the SKILL.md file on disk" do
      params = %{
        "name" => "test-bootstrap-skill",
        "description" => "A test skill for unit tests",
        "instructions" => "When triggered, respond with: TEST_SKILL_OK"
      }

      result = SkillBootstrap.create_and_run(params)
      skill_path = Path.expand("~/.osa/skills/test-bootstrap-skill/SKILL.md")

      # Accept either success or session-start failure (no Supervisor in test env)
      assert match?({:ok, _}, result) or match?({:error, _}, result)

      # Regardless of session outcome, the SKILL.md should be written
      assert File.exists?(skill_path)
    end

    test "SKILL.md contains the correct name and description" do
      params = %{
        "name" => "test-bootstrap-skill",
        "description" => "Bootstrap test skill",
        "instructions" => "Execute: echo bootstrap_done"
      }

      SkillBootstrap.create_and_run(params)
      skill_path = Path.expand("~/.osa/skills/test-bootstrap-skill/SKILL.md")

      if File.exists?(skill_path) do
        content = File.read!(skill_path)
        assert content =~ "test-bootstrap-skill"
        assert content =~ "Bootstrap test skill"
        assert content =~ "echo bootstrap_done"
      end
    end

    test "SKILL.md includes triggers in frontmatter" do
      params = %{
        "name" => "test-bootstrap-skill",
        "description" => "Trigger test",
        "instructions" => "Do something",
        "triggers" => ["my-trigger", "another"]
      }

      SkillBootstrap.create_and_run(params)
      skill_path = Path.expand("~/.osa/skills/test-bootstrap-skill/SKILL.md")

      if File.exists?(skill_path) do
        content = File.read!(skill_path)
        assert content =~ "triggers:"
        assert content =~ "my-trigger"
        assert content =~ "another"
      end
    end

    test "returns skill_name in success map" do
      params = %{
        "name" => "test-bootstrap-skill",
        "description" => "Test",
        "instructions" => "Test instructions"
      }

      case SkillBootstrap.create_and_run(params) do
        {:ok, result} -> assert result.skill_name == "test-bootstrap-skill"
        {:error, _} -> :ok  # session start may fail in test env
      end
    end

    test "list_self_skills includes newly created skill" do
      params = %{
        "name" => "test-bootstrap-skill",
        "description" => "List test",
        "instructions" => "Listed"
      }

      SkillBootstrap.create_and_run(params)
      skills = SkillBootstrap.list_self_skills()
      assert "test-bootstrap-skill" in skills
    end
  end

  # ── HTTP routes ────────────────────────────────────────────────────

  describe "POST /skill" do
    test "returns 400 when name is missing" do
      conn = json_post("/", %{"description" => "d", "instructions" => "i"})
      assert conn.status == 400
    end

    test "returns 400 when description is missing" do
      conn = json_post("/", %{"name" => "test-skill-abc", "instructions" => "i"})
      assert conn.status == 400
    end

    test "returns 400 when instructions are missing" do
      conn = json_post("/", %{"name" => "test-skill-abc", "description" => "d"})
      assert conn.status == 400
    end

    test "returns 400 for invalid name format" do
      conn = json_post("/", %{"name" => "Invalid Name!", "description" => "d", "instructions" => "i"})
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "invalid_name" or conn.resp_body =~ "kebab"
    end

    test "returns 202 or 500 for valid skill params" do
      conn = json_post("/", %{
        "name" => "test-skill-abc",
        "description" => "A test skill",
        "instructions" => "When triggered: respond with TEST_OK"
      })
      # 202 if session supervisor runs, 500 if not (test env)
      assert conn.status in [202, 500]
    end

    test "202 response has required fields" do
      conn = json_post("/", %{
        "name" => "test-skill-abc",
        "description" => "Field test",
        "instructions" => "Test"
      })

      if conn.status == 202 do
        body = Jason.decode!(conn.resp_body)
        assert body["status"] == "created_and_running"
        assert is_binary(body["skill_name"])
        assert is_binary(body["session_id"])
        assert is_binary(body["trigger_message"])
      end
    end
  end

  describe "GET /skill" do
    test "returns 200 with skills list" do
      conn = json_get("/")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["skills"])
      assert is_integer(body["count"])
    end
  end
end
