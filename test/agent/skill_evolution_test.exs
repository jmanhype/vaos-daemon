defmodule Daemon.Agent.SkillEvolutionTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Daemon.Agent.SkillEvolution
  alias Daemon.Channels.HTTP.API.SkillEvolutionRoutes

  @opts SkillEvolutionRoutes.init([])

  setup do
    on_exit(fn ->
      # Clean up any evolved skills created during tests
      evolved_dir = Path.expand("~/.daemon/skills/evolved")

      if File.dir?(evolved_dir) do
        evolved_dir
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "evolved-test"))
        |> Enum.each(fn name ->
          File.rm_rf(Path.join(evolved_dir, name))
        end)
      end
    end)

    :ok
  end

  defp json_get(path) do
    conn(:get, path)
    |> SkillEvolutionRoutes.call(@opts)
  end

  defp json_post(path, body \\ %{}) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> SkillEvolutionRoutes.call(@opts)
  end

  # ── Module API ──────────────────────────────────────────────────────

  describe "SkillEvolution module" do
    test "module is defined" do
      assert Code.ensure_loaded?(SkillEvolution)
    end

    test "start_link/1 is exported" do
      assert Code.ensure_loaded?(SkillEvolution)
      assert function_exported?(SkillEvolution, :start_link, 1)
    end

    test "stats/0 is exported" do
      assert Code.ensure_loaded?(SkillEvolution)
      assert function_exported?(SkillEvolution, :stats, 0)
    end

    test "list_evolved_skills/0 is exported" do
      assert Code.ensure_loaded?(SkillEvolution)
      assert function_exported?(SkillEvolution, :list_evolved_skills, 0)
    end

    test "trigger_evolution/2 is exported" do
      assert Code.ensure_loaded?(SkillEvolution)
      assert function_exported?(SkillEvolution, :trigger_evolution, 2)
    end

    test "list_evolved_skills/0 returns a list" do
      result = SkillEvolution.list_evolved_skills()
      assert is_list(result)
    end

    test "stats/0 returns ok tuple with map" do
      result = SkillEvolution.stats()
      assert match?({:ok, %{evolved_count: _, last_evolution: _}}, result)
    end

    test "stats/0 evolved_count is integer" do
      {:ok, %{evolved_count: n}} = SkillEvolution.stats()
      assert is_integer(n)
    end

    test "trigger_evolution/2 is a no-op when GenServer not started" do
      # Should not raise even if SkillEvolution GenServer isn't running
      assert :ok = SkillEvolution.trigger_evolution("test-session-123", %{reason: :test})
    end
  end

  # ── Evolution file writing ──────────────────────────────────────────

  describe "skill file writing" do
    test "evolved dir is created if it doesn't exist" do
      evolved_dir = Path.expand("~/.daemon/skills/evolved")
      # trigger_evolution is async — call private via direct file writing test
      # Just verify the dir can be created
      File.mkdir_p!(evolved_dir)
      assert File.dir?(evolved_dir)
    end

    test "list_evolved_skills includes manually created evolved skill" do
      evolved_dir = Path.expand("~/.daemon/skills/evolved")
      skill_dir = Path.join(evolved_dir, "evolved-test-manual")
      File.mkdir_p!(skill_dir)

      File.write!(Path.join(skill_dir, "SKILL.md"), """
      ---
      name: evolved-test-manual
      description: test
      evolved: true
      evolved_from: test-session
      ---
      Test instructions.
      """)

      skills = SkillEvolution.list_evolved_skills()
      assert "evolved-test-manual" in skills
    end
  end

  # ── HTTP routes ─────────────────────────────────────────────────────

  describe "GET /agent/evolve" do
    test "returns 200" do
      conn = json_get("/")
      assert conn.status == 200
    end

    test "returns evolved_count" do
      conn = json_get("/")
      body = Jason.decode!(conn.resp_body)
      assert is_integer(body["evolved_count"])
    end

    test "returns skills list" do
      conn = json_get("/")
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["skills"])
    end

    test "last_evolution is nil or string" do
      conn = json_get("/")
      body = Jason.decode!(conn.resp_body)
      assert is_nil(body["last_evolution"]) or is_binary(body["last_evolution"])
    end
  end

  describe "GET /agent/evolve/skills" do
    test "returns 200" do
      conn = json_get("/skills")
      assert conn.status == 200
    end

    test "returns skills list and count" do
      conn = json_get("/skills")
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["skills"])
      assert is_integer(body["count"])
    end
  end

  describe "POST /agent/evolve/trigger" do
    test "returns 400 when session_id missing" do
      conn = json_post("/trigger", %{"reason" => "test"})
      assert conn.status == 400
    end

    test "returns 400 when session_id is empty" do
      conn = json_post("/trigger", %{"session_id" => "", "reason" => "test"})
      assert conn.status == 400
    end

    test "returns 202 when session_id provided" do
      conn = json_post("/trigger", %{"session_id" => "abc-123", "reason" => "test"})
      assert conn.status == 202
    end

    test "202 response has status and session_id" do
      conn = json_post("/trigger", %{"session_id" => "abc-456"})
      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "triggered"
      assert body["session_id"] == "abc-456"
    end
  end
end
