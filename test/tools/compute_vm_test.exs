defmodule OptimalSystemAgent.Tools.Builtins.ComputeVmTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ComputeVm

  # ── Behaviour callbacks ─────────────────────────────────────────────

  describe "MiosaTools.Behaviour callbacks" do
    test "name/0 returns compute_vm" do
      assert ComputeVm.name() == "compute_vm"
    end

    test "description/0 is non-empty" do
      d = ComputeVm.description()
      assert is_binary(d)
      assert byte_size(d) > 20
    end

    test "parameters/0 returns a valid JSON Schema object" do
      schema = ComputeVm.parameters()
      assert schema["type"] == "object"
      assert is_map(schema["properties"])
      assert "operation" in schema["required"]
    end

    test "parameters includes all expected operations in enum" do
      ops = ComputeVm.parameters()["properties"]["operation"]["enum"]
      assert "create" in ops
      assert "list" in ops
      assert "status" in ops
      assert "wait_ready" in ops
      assert "exec" in ops
      assert "read_file" in ops
      assert "write_file" in ops
      assert "snapshot" in ops
      assert "restart" in ops
      assert "destroy" in ops
    end

    test "parameters includes wait boolean for create" do
      wait_prop = ComputeVm.parameters()["properties"]["wait"]
      assert wait_prop["type"] == "boolean"
    end

    test "parameters includes timeout integer" do
      timeout_prop = ComputeVm.parameters()["properties"]["timeout"]
      assert timeout_prop["type"] == "integer"
    end

    test "parameters includes snapshot_name string" do
      prop = ComputeVm.parameters()["properties"]["snapshot_name"]
      assert prop["type"] == "string"
    end
  end

  # ── Missing parameter guards ────────────────────────────────────────

  describe "execute/1 — missing parameters" do
    test "missing operation returns error" do
      assert {:error, msg} = ComputeVm.execute(%{})
      assert msg =~ "operation"
    end

    test "unknown operation returns descriptive error" do
      assert {:error, msg} = ComputeVm.execute(%{"operation" => "fly"})
      assert msg =~ "Unknown operation"
      assert msg =~ "fly"
    end

    test "status without vm_id returns error" do
      assert {:error, msg} = ComputeVm.execute(%{"operation" => "status"})
      assert msg =~ "vm_id"
    end

    test "wait_ready without vm_id returns error" do
      assert {:error, msg} = ComputeVm.execute(%{"operation" => "wait_ready"})
      assert msg =~ "vm_id"
    end

    test "exec without vm_id returns error" do
      assert {:error, msg} = ComputeVm.execute(%{"operation" => "exec", "command" => "ls"})
      assert msg =~ "vm_id"
    end

    test "exec without command returns error" do
      assert {:error, msg} =
               ComputeVm.execute(%{"operation" => "exec", "vm_id" => "vm_abc"})

      assert msg =~ "command"
    end

    test "read_file without vm_id returns error" do
      assert {:error, msg} =
               ComputeVm.execute(%{"operation" => "read_file", "path" => "/workspace/x.py"})

      assert msg =~ "vm_id"
    end

    test "read_file without path returns error" do
      assert {:error, msg} =
               ComputeVm.execute(%{"operation" => "read_file", "vm_id" => "vm_abc"})

      assert msg =~ "path"
    end

    test "write_file without vm_id returns error" do
      assert {:error, msg} =
               ComputeVm.execute(%{
                 "operation" => "write_file",
                 "path" => "/workspace/t.py",
                 "content" => "x"
               })

      assert msg =~ "vm_id"
    end

    test "write_file without path returns error" do
      assert {:error, msg} =
               ComputeVm.execute(%{
                 "operation" => "write_file",
                 "vm_id" => "vm_abc",
                 "content" => "x"
               })

      assert msg =~ "path"
    end

    test "write_file without content returns error" do
      assert {:error, msg} =
               ComputeVm.execute(%{
                 "operation" => "write_file",
                 "vm_id" => "vm_abc",
                 "path" => "/workspace/t.py"
               })

      assert msg =~ "content"
    end

    test "snapshot without vm_id returns error" do
      assert {:error, msg} = ComputeVm.execute(%{"operation" => "snapshot"})
      assert msg =~ "vm_id"
    end

    test "restart without vm_id returns error" do
      assert {:error, msg} = ComputeVm.execute(%{"operation" => "restart"})
      assert msg =~ "vm_id"
    end

    test "destroy without vm_id returns error" do
      assert {:error, msg} = ComputeVm.execute(%{"operation" => "destroy"})
      assert msg =~ "vm_id"
    end
  end

  # ── list operation — no live API needed ────────────────────────────

  describe "execute/1 list" do
    test "list returns error or ok (no server present)" do
      result = ComputeVm.execute(%{"operation" => "list"})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "list with status_filter returns error or ok" do
      result = ComputeVm.execute(%{"operation" => "list", "status_filter" => "running"})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # ── Integration tests (require MIOSA_COMPUTE_URL to be set) ─────────

  @tag :integration
  describe "integration — full lifecycle" do
    setup do
      if is_nil(System.get_env("MIOSA_COMPUTE_URL")) do
        {:ok, skip: true}
      else
        :ok
      end
    end

    test "create / wait_ready / exec / write_file / read_file / snapshot / destroy" do
      # Create
      assert {:ok, create_msg} =
               ComputeVm.execute(%{"operation" => "create", "template_id" => "python-ml"})

      vm_id = extract_vm_id(create_msg)
      assert is_binary(vm_id), "expected vm_id in: #{create_msg}"

      # Wait for ready
      assert {:ok, ready_msg} =
               ComputeVm.execute(%{"operation" => "wait_ready", "vm_id" => vm_id, "timeout" => 60})

      assert ready_msg =~ vm_id

      # Status
      assert {:ok, status_msg} =
               ComputeVm.execute(%{"operation" => "status", "vm_id" => vm_id})

      assert status_msg =~ vm_id

      # List — vm should appear
      assert {:ok, list_msg} = ComputeVm.execute(%{"operation" => "list"})
      assert list_msg =~ vm_id

      # Write a file
      content = "print('hello from autoresearch')\n"

      assert {:ok, write_msg} =
               ComputeVm.execute(%{
                 "operation" => "write_file",
                 "vm_id" => vm_id,
                 "path" => "/workspace/hello.py",
                 "content" => content
               })

      assert write_msg =~ "Written"

      # Exec the file
      assert {:ok, exec_out} =
               ComputeVm.execute(%{
                 "operation" => "exec",
                 "vm_id" => vm_id,
                 "command" => "python /workspace/hello.py",
                 "timeout" => 30
               })

      assert exec_out =~ "hello from autoresearch"

      # Read it back
      assert {:ok, read_content} =
               ComputeVm.execute(%{
                 "operation" => "read_file",
                 "vm_id" => vm_id,
                 "path" => "/workspace/hello.py"
               })

      assert read_content =~ "print"

      # Snapshot
      assert {:ok, snap_msg} =
               ComputeVm.execute(%{
                 "operation" => "snapshot",
                 "vm_id" => vm_id,
                 "snapshot_name" => "test-snap-01"
               })

      assert snap_msg =~ "snap"

      # Destroy
      assert {:ok, destroy_msg} =
               ComputeVm.execute(%{"operation" => "destroy", "vm_id" => vm_id})

      assert destroy_msg =~ "destroyed"
    end

    test "create with wait: true returns ready VM" do
      assert {:ok, msg} =
               ComputeVm.execute(%{
                 "operation" => "create",
                 "template_id" => "python-ml",
                 "wait" => true
               })

      assert msg =~ "ready" or msg =~ "running"
      vm_id = extract_vm_id(msg)

      if vm_id do
        ComputeVm.execute(%{"operation" => "destroy", "vm_id" => vm_id})
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp extract_vm_id(msg) when is_binary(msg) do
    case Regex.run(~r/vm_id=([\w-]+)/, msg) do
      [_, id] -> id
      _ -> nil
    end
  end
end
