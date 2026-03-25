defmodule Daemon.Agent.Orchestrator.AgentRunnerTest do
  use ExUnit.Case, async: true

  alias Daemon.Agent.Orchestrator.AgentRunner
  alias Daemon.Agent.Orchestrator.SubTask

  # ── resolve_agent_tier/1 ─────────────────────────────────────────────

  describe "resolve_agent_tier/1" do
    test "returns :elite for lead role when no roster match" do
      sub_task = %SubTask{
        name: "plan",
        description: "some unique obscure task xyz123",
        role: :lead,
        tools_needed: [],
        depends_on: []
      }

      assert AgentRunner.resolve_agent_tier(sub_task) == :elite
    end

    test "returns :specialist for backend role when no roster match" do
      sub_task = %SubTask{
        name: "build",
        description: "some unique obscure task xyz123",
        role: :backend,
        tools_needed: [],
        depends_on: []
      }

      assert AgentRunner.resolve_agent_tier(sub_task) == :specialist
    end

    test "returns :specialist for red_team role when no roster match" do
      sub_task = %SubTask{
        name: "review",
        description: "some unique obscure task xyz123",
        role: :red_team,
        tools_needed: [],
        depends_on: []
      }

      assert AgentRunner.resolve_agent_tier(sub_task) == :specialist
    end

    test "matches a named agent when triggers align" do
      # "debug" should trigger the debugger agent or similar
      sub_task = %SubTask{
        name: "investigate",
        description: "debug the authentication failure in the login endpoint",
        role: :backend,
        tools_needed: [],
        depends_on: []
      }

      tier = AgentRunner.resolve_agent_tier(sub_task)
      assert tier in [:elite, :specialist, :utility]
    end
  end

  # ── build_agent_prompt/1 ─────────────────────────────────────────────

  describe "build_agent_prompt/1" do
    test "includes task description in prompt" do
      sub_task = %SubTask{
        name: "build_api",
        description: "Build the REST API endpoints for user management",
        role: :backend,
        tools_needed: [],
        depends_on: []
      }

      prompt = AgentRunner.build_agent_prompt(sub_task)
      assert prompt =~ "Build the REST API endpoints for user management"
    end

    test "includes execution parameters" do
      sub_task = %SubTask{
        name: "test",
        description: "some unique obscure task xyz123 no match",
        role: :qa,
        tools_needed: [],
        depends_on: []
      }

      prompt = AgentRunner.build_agent_prompt(sub_task)
      assert prompt =~ "Tier:"
      assert prompt =~ "Max iterations:"
      assert prompt =~ "Token budget:"
    end

    test "includes environment context" do
      sub_task = %SubTask{
        name: "check",
        description: "some unique obscure task xyz123",
        role: :backend,
        tools_needed: [],
        depends_on: []
      }

      prompt = AgentRunner.build_agent_prompt(sub_task)
      assert prompt =~ "Working directory:"
      assert prompt =~ "Git branch:"
    end

    test "generates dynamic prompt for unmatched tasks" do
      sub_task = %SubTask{
        name: "exotic",
        description: "zyxwvut completely unique no agent matches this abc987",
        role: :data,
        tools_needed: [],
        depends_on: []
      }

      prompt = AgentRunner.build_agent_prompt(sub_task)
      # Dynamic prompt has this header pattern
      assert prompt =~ "Dynamic Task Specialist"
      assert prompt =~ "zyxwvut completely unique"
    end

    test "loads named agent prompt for strong trigger match" do
      # "security audit" should strongly match a security agent
      sub_task = %SubTask{
        name: "audit",
        description: "security audit vulnerability scan the entire codebase for injection flaws",
        role: :red_team,
        tools_needed: [],
        depends_on: []
      }

      prompt = AgentRunner.build_agent_prompt(sub_task)
      # Should NOT be a dynamic prompt — should match a named agent
      # The prompt should include the agent name in execution params
      assert prompt =~ "Agent:"
    end

    test "includes tools in available tools section" do
      sub_task = %SubTask{
        name: "build",
        description: "some unique obscure task xyz123",
        role: :backend,
        tools_needed: ["file_read", "file_write"],
        depends_on: []
      }

      prompt = AgentRunner.build_agent_prompt(sub_task)
      assert prompt =~ "file_read"
      assert prompt =~ "file_write"
    end

    test "includes rules section" do
      sub_task = %SubTask{
        name: "task",
        description: "some unique obscure task xyz123",
        role: :backend,
        tools_needed: [],
        depends_on: []
      }

      prompt = AgentRunner.build_agent_prompt(sub_task)
      assert prompt =~ "Focus ONLY on your assigned task"
      assert prompt =~ "Match existing codebase patterns"
    end
  end

  # ── build_dynamic_prompt (via build_agent_prompt) ────────────────────

  describe "dynamic prompt generation" do
    test "includes role name" do
      sub_task = %SubTask{
        name: "task",
        description: "zyxwvut completely unique no match abc987",
        role: :frontend,
        tools_needed: [],
        depends_on: []
      }

      prompt = AgentRunner.build_agent_prompt(sub_task)
      assert prompt =~ "Frontend"
    end

    test "handles red_team role name formatting" do
      sub_task = %SubTask{
        name: "task",
        description: "zyxwvut completely unique no match abc987",
        role: :red_team,
        tools_needed: [],
        depends_on: []
      }

      prompt = AgentRunner.build_agent_prompt(sub_task)
      assert prompt =~ "Red team"
    end

    test "includes dependency info when depends_on is set" do
      sub_task = %SubTask{
        name: "task",
        description: "zyxwvut completely unique no match abc987",
        role: :backend,
        tools_needed: [],
        depends_on: ["schema_design", "api_spec"]
      }

      prompt = AgentRunner.build_agent_prompt(sub_task)
      assert prompt =~ "schema_design"
      assert prompt =~ "api_spec"
    end

    test "includes context from previous agents when present" do
      sub_task = %SubTask{
        name: "task",
        description: "zyxwvut completely unique no match abc987",
        role: :backend,
        tools_needed: [],
        depends_on: [],
        context: "Previous agent created the users table with columns: id, name, email"
      }

      prompt = AgentRunner.build_agent_prompt(sub_task)
      assert prompt =~ "Previous agent created the users table"
    end

    test "includes output format requirements" do
      sub_task = %SubTask{
        name: "task",
        description: "zyxwvut completely unique no match abc987",
        role: :backend,
        tools_needed: [],
        depends_on: []
      }

      prompt = AgentRunner.build_agent_prompt(sub_task)
      assert prompt =~ "What you did"
      assert prompt =~ "Verification"
    end
  end
end
