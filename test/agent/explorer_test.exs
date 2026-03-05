defmodule OptimalSystemAgent.Agent.ExplorerTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Explorer

  # ── should_explore?/2 ────────────────────────────────────────

  describe "should_explore?/2" do
    @base_state %{exploration_done: false, plan_mode: false}

    test "returns true for code modification messages" do
      assert Explorer.should_explore?("fix the authentication bug in the login handler", @base_state)
      assert Explorer.should_explore?("add a new endpoint for user registration in the API module", @base_state)
      assert Explorer.should_explore?("refactor the database module to use connection pooling", @base_state)
      assert Explorer.should_explore?("implement the search function in the controller", @base_state)
      assert Explorer.should_explore?("update the test file for the auth component", @base_state)
    end

    test "returns true for file path references" do
      assert Explorer.should_explore?("please look at lib/my_app/auth.ex and fix the issue there", @base_state)
      assert Explorer.should_explore?("modify the handler.ts to add error handling for edge cases", @base_state)
      assert Explorer.should_explore?("there's a bug in server.go that causes panics under load", @base_state)
    end

    test "returns true for project/codebase references with action intent" do
      assert Explorer.should_explore?("explore this project and fix the authentication module issues", @base_state)
      assert Explorer.should_explore?("look at this codebase and add the missing test file for auth", @base_state)
    end

    test "returns false for short messages" do
      refute Explorer.should_explore?("hi", @base_state)
      refute Explorer.should_explore?("ok", @base_state)
      refute Explorer.should_explore?("thanks", @base_state)
      refute Explorer.should_explore?("yes please", @base_state)
    end

    test "returns false for casual messages" do
      refute Explorer.should_explore?("hello there, how are you doing today?", @base_state)
      refute Explorer.should_explore?("thanks for the help with the previous task!", @base_state)
      refute Explorer.should_explore?("goodbye and see ya later, have a great day!", @base_state)
    end

    test "returns false for memory operations" do
      refute Explorer.should_explore?("remember this pattern for future reference please", @base_state)
      refute Explorer.should_explore?("what do you remember about the auth setup from last time?", @base_state)
    end

    test "returns false for pure questions without code context" do
      refute Explorer.should_explore?("what is the difference between TCP and UDP protocols?", @base_state)
      refute Explorer.should_explore?("explain how garbage collection works in modern runtimes", @base_state)
      refute Explorer.should_explore?("how does the internet DNS resolution system work?", @base_state)
    end

    test "returns false for shell commands" do
      refute Explorer.should_explore?("run mix test to check if everything passes correctly", @base_state)
      refute Explorer.should_explore?("execute npm install to get the latest dependencies", @base_state)
    end

    test "returns false when exploration already done" do
      state = %{@base_state | exploration_done: true}
      refute Explorer.should_explore?("fix the authentication bug in the handler", state)
    end

    test "returns false in plan mode" do
      state = %{@base_state | plan_mode: true}
      refute Explorer.should_explore?("fix the authentication bug in the handler", state)
    end
  end

  # ── maybe_explore/2 ──────────────────────────────────────────

  describe "maybe_explore/2" do
    test "returns {:skip, state} for casual messages" do
      state = %{
        exploration_done: false,
        plan_mode: false,
        messages: [%{role: "user", content: "hello there"}]
      }
      assert {:skip, _} = Explorer.maybe_explore(state, "hello there")
    end

    test "returns {:skip, state} when already explored" do
      state = %{
        exploration_done: true,
        plan_mode: false,
        messages: [%{role: "user", content: "fix the auth bug in the handler"}]
      }
      assert {:skip, _} = Explorer.maybe_explore(state, "fix the auth bug in the handler")
    end

    test "attempts exploration for code modification messages and handles missing tools gracefully" do
      state = %{
        exploration_done: false,
        plan_mode: false,
        explored_files: MapSet.new(),
        messages: [%{role: "user", content: "fix the authentication bug in the handler module"}],
        session_id: "test-explorer-#{:erlang.unique_integer([:positive])}"
      }

      # This will either explore successfully or skip gracefully
      # depending on whether Tools.Registry is running
      result = Explorer.maybe_explore(state, "fix the authentication bug in the handler module")
      assert elem(result, 0) in [:explored, :skip]
    end
  end

  # ── extract_keywords (tested via run_exploration) ────────────

  describe "keyword extraction" do
    test "run_exploration extracts meaningful keywords" do
      # We test this indirectly by verifying run_exploration doesn't crash
      # and returns a tuple with context and files list
      {context, files} = Explorer.run_exploration("fix auth handler", %{})
      assert is_binary(context)
      assert is_list(files)
    end
  end
end
