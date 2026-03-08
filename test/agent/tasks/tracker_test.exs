defmodule OptimalSystemAgent.Agent.Tasks.TrackerTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Tasks
  alias OptimalSystemAgent.Agent.Tasks.Tracker

  # ── Helpers ──────────────────────────────────────────────────────

  defp start_tracker do
    name = :"tracker_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = Tasks.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {pid, name}
  end

  defp session_id do
    id = "test_tracker_#{System.unique_integer([:positive, :monotonic])}"

    on_exit(fn ->
      base = System.get_env("OSA_HOME") || Path.expand("~/.osa")
      dir = Path.join([base, "sessions", id])
      File.rm_rf(dir)
    end)

    id
  end

  # ── add_task ────────────────────────────────────────────────────

  describe "add_task/3" do
    test "returns ok with task id" do
      {_pid, name} = start_tracker()
      sid = session_id()
      assert {:ok, id} = Tasks.add_task(sid, "Do something", name)
      assert is_binary(id)
      assert String.length(id) == 8
    end

    test "task starts as pending" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, _id} = Tasks.add_task(sid, "My task", name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :pending
      assert task.title == "My task"
      assert task.tokens_used == 0
    end

    test "multiple adds accumulate in order" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, _} = Tasks.add_task(sid, "First", name)
      {:ok, _} = Tasks.add_task(sid, "Second", name)
      {:ok, _} = Tasks.add_task(sid, "Third", name)
      tasks = Tasks.get_tasks(sid, name)
      assert length(tasks) == 3
      assert Enum.map(tasks, & &1.title) == ["First", "Second", "Third"]
    end
  end

  # ── add_tasks (bulk) ───────────────────────────────────────────

  describe "add_tasks/3" do
    test "adds multiple tasks at once" do
      {_pid, name} = start_tracker()
      sid = session_id()
      titles = ["Task A", "Task B", "Task C"]
      assert {:ok, ids} = Tasks.add_tasks(sid, titles, name)
      assert length(ids) == 3
      tasks = Tasks.get_tasks(sid, name)
      assert Enum.map(tasks, & &1.title) == titles
    end

    test "empty list returns empty ids" do
      {_pid, name} = start_tracker()
      sid = session_id()
      assert {:ok, []} = Tasks.add_tasks(sid, [], name)
      assert Tasks.get_tasks(sid, name) == []
    end
  end

  # ── start_task ─────────────────────────────────────────────────

  describe "start_task/3" do
    test "transitions to in_progress" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "Work item", name)
      assert :ok = Tasks.start_task(sid, id, name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :in_progress
      assert task.started_at != nil
    end

    test "returns error for unknown task" do
      {_pid, name} = start_tracker()
      sid = session_id()
      assert {:error, :not_found} = Tasks.start_task(sid, "nonexistent", name)
    end
  end

  # ── complete_task ──────────────────────────────────────────────

  describe "complete_task/3" do
    test "transitions to completed" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "Finish me", name)
      Tasks.start_task(sid, id, name)
      assert :ok = Tasks.complete_task(sid, id, name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :completed
      assert task.completed_at != nil
    end

    test "can complete without starting first" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "Skip ahead", name)
      assert :ok = Tasks.complete_task(sid, id, name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :completed
    end

    test "returns error for unknown task" do
      {_pid, name} = start_tracker()
      sid = session_id()
      assert {:error, :not_found} = Tasks.complete_task(sid, "bad_id", name)
    end
  end

  # ── fail_task ──────────────────────────────────────────────────

  describe "fail_task/4" do
    test "transitions to failed with reason" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "Will fail", name)
      Tasks.start_task(sid, id, name)
      assert :ok = Tasks.fail_task(sid, id, "timeout", name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :failed
      assert task.reason == "timeout"
      assert task.completed_at != nil
    end

    test "returns error for unknown task" do
      {_pid, name} = start_tracker()
      sid = session_id()
      assert {:error, :not_found} = Tasks.fail_task(sid, "nope", "err", name)
    end
  end

  # ── get_tasks ──────────────────────────────────────────────────

  describe "get_tasks/2" do
    test "returns empty list for unknown session" do
      {_pid, name} = start_tracker()
      assert Tasks.get_tasks("no_such_session", name) == []
    end

    test "returns tasks in insertion order" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, _} = Tasks.add_task(sid, "A", name)
      {:ok, _} = Tasks.add_task(sid, "B", name)
      tasks = Tasks.get_tasks(sid, name)
      assert [%{title: "A"}, %{title: "B"}] = tasks
    end
  end

  # ── clear_tasks ────────────────────────────────────────────────

  describe "clear_tasks/2" do
    test "removes all tasks for a session" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, _} = Tasks.add_task(sid, "Remove me", name)
      assert :ok = Tasks.clear_tasks(sid, name)
      assert Tasks.get_tasks(sid, name) == []
    end

    test "does not affect other sessions" do
      {_pid, name} = start_tracker()
      sid1 = session_id()
      sid2 = session_id()
      {:ok, _} = Tasks.add_task(sid1, "S1 task", name)
      {:ok, _} = Tasks.add_task(sid2, "S2 task", name)
      Tasks.clear_tasks(sid1, name)
      assert Tasks.get_tasks(sid1, name) == []
      assert length(Tasks.get_tasks(sid2, name)) == 1
    end
  end

  # ── record_tokens ──────────────────────────────────────────────

  describe "record_tokens/4" do
    test "accumulates token count" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "Token task", name)
      Tasks.record_tokens(sid, id, 500, name)
      _ = Tasks.get_tasks(sid, name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.tokens_used == 500

      Tasks.record_tokens(sid, id, 300, name)
      _ = Tasks.get_tasks(sid, name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.tokens_used == 800
    end
  end

  # ── extract_tasks_from_response ────────────────────────────────

  describe "extract_tasks_from_response/1" do
    test "parses numbered list" do
      text = """
      Here's the plan:
      1. Explore the codebase structure
      2. Identify authentication patterns
      3. Design the API schema
      4. Implement user endpoints
      5. Write integration tests
      """

      titles = Tasks.extract_tasks_from_response(text)
      assert length(titles) == 5
      assert "Explore the codebase structure" in titles
      assert "Write integration tests" in titles
    end

    test "parses markdown checkboxes" do
      text = """
      - [ ] Set up the database schema
      - [ ] Create migration files
      - [x] Review requirements
      - [ ] Write the controller
      """

      titles = Tasks.extract_tasks_from_response(text)
      assert length(titles) == 4
      assert "Set up the database schema" in titles
      assert "Review requirements" in titles
    end

    test "filters titles outside 5-120 chars" do
      text = """
      1. Hi
      2. This is a valid task title
      3. #{String.duplicate("x", 121)}
      """

      titles = Tasks.extract_tasks_from_response(text)
      assert length(titles) == 1
      assert "This is a valid task title" in titles
    end

    test "caps at 20 tasks" do
      lines = Enum.map_join(1..25, "\n", fn i -> "#{i}. Task number #{i} here" end)
      titles = Tasks.extract_tasks_from_response(lines)
      assert length(titles) == 20
    end

    test "deduplicates titles" do
      text = """
      1. Same task repeated
      2. Same task repeated
      3. A different task here
      """

      titles = Tasks.extract_tasks_from_response(text)
      assert length(titles) == 2
    end

    test "returns empty for non-list text" do
      assert Tasks.extract_tasks_from_response("Just a paragraph of text.") == []
    end

    test "returns empty for nil" do
      assert Tasks.extract_tasks_from_response(nil) == []
    end
  end

  # ── Persistence roundtrip ──────────────────────────────────────

  describe "persistence" do
    test "tasks survive restart" do
      sid = session_id()
      name1 = :"tracker_persist_#{:erlang.unique_integer([:positive])}"
      {:ok, pid1} = Tasks.start_link(name: name1)
      {:ok, _id} = Tasks.add_task(sid, "Persistent task", name1)
      GenServer.stop(pid1)

      name2 = :"tracker_persist_#{:erlang.unique_integer([:positive])}"
      {:ok, pid2} = Tasks.start_link(name: name2)

      on_exit(fn ->
        if Process.alive?(pid2), do: GenServer.stop(pid2)
        base = System.get_env("OSA_HOME") || Path.expand("~/.osa")
        path = Path.join([base, "sessions", sid, "tasks.json"])
        File.rm(path)
      end)

      tasks = Tasks.get_tasks(sid, name2)
      assert length(tasks) == 1
      assert hd(tasks).title == "Persistent task"
    end
  end

  # ── extract_from_response (direct module) ─────────────────────

  describe "Tracker.extract_from_response/1" do
    test "delegates correctly" do
      text = "1. First task here\n2. Second task here\n3. Third task here"
      assert length(Tracker.extract_from_response(text)) == 3
    end
  end
end
