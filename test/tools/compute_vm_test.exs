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
      assert "status" in ops
      assert "exec" in ops
      assert "read_file" in ops
      assert "write_file" in ops
      assert "destroy" in ops
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

    test "destroy without vm_id returns error" do
      assert {:error, msg} = ComputeVm.execute(%{"operation" => "destroy"})
      assert msg =~ "vm_id"
    end
  end

  # ── Integration tests (require MIOSA_COMPUTE_URL to be set) ─────────

  @tag :integration
  describe "integration — create / exec / read_file / write_file / destroy" do
    setup do
      if is_nil(System.get_env("MIOSA_COMPUTE_URL")) do
        {:ok, skip: true}
      else
        :ok
      end
    end

    test "full lifecycle" do
      # Create
      assert {:ok, create_msg} =
               ComputeVm.execute(%{"operation" => "create", "template_id" => "python-ml"})

      vm_id = extract_vm_id(create_msg)
      assert is_binary(vm_id), "expected vm_id in: #{create_msg}"

      # Status
      assert {:ok, status_msg} =
               ComputeVm.execute(%{"operation" => "status", "vm_id" => vm_id})

      assert status_msg =~ vm_id

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

      # Destroy
      assert {:ok, destroy_msg} =
               ComputeVm.execute(%{"operation" => "destroy", "vm_id" => vm_id})

      assert destroy_msg =~ "destroyed"
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
