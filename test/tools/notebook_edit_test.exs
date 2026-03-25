defmodule Daemon.Tools.Builtins.NotebookEditTest do
  use ExUnit.Case, async: true

  alias Daemon.Tools.Builtins.NotebookEdit

  @sample_notebook %{
    "nbformat" => 4,
    "nbformat_minor" => 5,
    "metadata" => %{"kernelspec" => %{"display_name" => "Python 3", "language" => "python", "name" => "python3"}},
    "cells" => [
      %{
        "cell_type" => "code",
        "source" => ["import pandas as pd\n", "df = pd.read_csv(\"data.csv\")"],
        "metadata" => %{},
        "execution_count" => 1,
        "outputs" => [%{"output_type" => "execute_result", "text" => ["DataFrame with 100 rows"]}]
      },
      %{
        "cell_type" => "markdown",
        "source" => ["# Analysis Results\n", "Below are the key findings."],
        "metadata" => %{}
      },
      %{
        "cell_type" => "code",
        "source" => ["print(\"hello\")"],
        "metadata" => %{},
        "execution_count" => 2,
        "outputs" => []
      }
    ]
  }

  defp write_notebook(path, notebook \\ nil) do
    nb = notebook || @sample_notebook
    File.write!(path, Jason.encode!(nb))
  end

  defp tmp_path do
    "/tmp/osa_nb_test_#{:rand.uniform(1_000_000)}.ipynb"
  end

  # ── Tool metadata ────────────────────────────────────────────────

  describe "tool metadata" do
    test "name returns notebook_edit" do
      assert NotebookEdit.name() == "notebook_edit"
    end

    test "safety returns :write_safe" do
      assert NotebookEdit.safety() == :write_safe
    end

    test "parameters returns valid JSON schema with required fields" do
      params = NotebookEdit.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "action")
      assert Map.has_key?(params["properties"], "path")
      assert params["required"] == ["action", "path"]
    end

    test "description mentions Jupyter notebooks" do
      assert NotebookEdit.description() =~ "Jupyter"
    end
  end

  # ── Read action ──────────────────────────────────────────────────

  describe "read" do
    test "displays all cells with index, type, and content" do
      path = tmp_path()

      try do
        write_notebook(path)
        assert {:ok, output} = NotebookEdit.execute(%{"action" => "read", "path" => path})
        assert output =~ "[0] code:"
        assert output =~ "import pandas as pd"
        assert output =~ "[1] markdown:"
        assert output =~ "# Analysis Results"
        assert output =~ "[2] code:"
        assert output =~ "print(\"hello\")"
      after
        File.rm(path)
      end
    end

    test "shows output summary for code cells with outputs" do
      path = tmp_path()

      try do
        write_notebook(path)
        assert {:ok, output} = NotebookEdit.execute(%{"action" => "read", "path" => path})
        assert output =~ "--- Output:"
        assert output =~ "DataFrame with 100 rows"
      after
        File.rm(path)
      end
    end

    test "handles empty notebook" do
      path = tmp_path()

      try do
        write_notebook(path, %{"nbformat" => 4, "nbformat_minor" => 5, "metadata" => %{}, "cells" => []})
        assert {:ok, output} = NotebookEdit.execute(%{"action" => "read", "path" => path})
        assert output =~ "Empty notebook"
      after
        File.rm(path)
      end
    end

    test "returns error for nonexistent file" do
      assert {:error, msg} =
               NotebookEdit.execute(%{"action" => "read", "path" => "/tmp/osa_nb_nonexistent_#{:rand.uniform(100_000)}.ipynb"})

      assert msg =~ "not found"
    end

    test "returns error for invalid JSON" do
      path = tmp_path()

      try do
        File.write!(path, "not json{{{")
        assert {:error, msg} = NotebookEdit.execute(%{"action" => "read", "path" => path})
        assert msg =~ "parse JSON"
      after
        File.rm(path)
      end
    end
  end

  # ── Add cell action ─────────────────────────────────────────────

  describe "add_cell" do
    test "appends cell to end by default" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:ok, msg} =
                 NotebookEdit.execute(%{
                   "action" => "add_cell",
                   "path" => path,
                   "source" => "x = 42",
                   "cell_type" => "code"
                 })

        assert msg =~ "Added code cell"

        nb = path |> File.read!() |> Jason.decode!()
        assert length(nb["cells"]) == 4
        last = List.last(nb["cells"])
        assert last["cell_type"] == "code"
        assert last["source"] == ["x = 42"]
        assert last["outputs"] == []
      after
        File.rm(path)
      end
    end

    test "inserts cell at specified position" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:ok, _} =
                 NotebookEdit.execute(%{
                   "action" => "add_cell",
                   "path" => path,
                   "source" => "# Inserted",
                   "cell_type" => "markdown",
                   "position" => 1
                 })

        nb = path |> File.read!() |> Jason.decode!()
        assert length(nb["cells"]) == 4
        assert Enum.at(nb["cells"], 1)["cell_type"] == "markdown"
        assert Enum.at(nb["cells"], 1)["source"] == ["# Inserted"]
      after
        File.rm(path)
      end
    end

    test "defaults cell_type to code" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:ok, _} =
                 NotebookEdit.execute(%{
                   "action" => "add_cell",
                   "path" => path,
                   "source" => "y = 1"
                 })

        nb = path |> File.read!() |> Jason.decode!()
        last = List.last(nb["cells"])
        assert last["cell_type"] == "code"
      after
        File.rm(path)
      end
    end

    test "adds markdown cell without outputs field" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:ok, _} =
                 NotebookEdit.execute(%{
                   "action" => "add_cell",
                   "path" => path,
                   "source" => "# Title",
                   "cell_type" => "markdown"
                 })

        nb = path |> File.read!() |> Jason.decode!()
        last = List.last(nb["cells"])
        assert last["cell_type"] == "markdown"
        refute Map.has_key?(last, "outputs")
      after
        File.rm(path)
      end
    end

    test "handles multiline source" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:ok, _} =
                 NotebookEdit.execute(%{
                   "action" => "add_cell",
                   "path" => path,
                   "source" => "line1\nline2\nline3"
                 })

        nb = path |> File.read!() |> Jason.decode!()
        last = List.last(nb["cells"])
        assert last["source"] == ["line1\n", "line2\n", "line3"]
      after
        File.rm(path)
      end
    end
  end

  # ── Edit cell action ────────────────────────────────────────────

  describe "edit_cell" do
    test "updates source at given index" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:ok, msg} =
                 NotebookEdit.execute(%{
                   "action" => "edit_cell",
                   "path" => path,
                   "index" => 0,
                   "source" => "import numpy as np"
                 })

        assert msg =~ "Edited cell [0]"

        nb = path |> File.read!() |> Jason.decode!()
        assert Enum.at(nb["cells"], 0)["source"] == ["import numpy as np"]
      after
        File.rm(path)
      end
    end

    test "preserves outputs when editing code cell" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:ok, _} =
                 NotebookEdit.execute(%{
                   "action" => "edit_cell",
                   "path" => path,
                   "index" => 0,
                   "source" => "new code"
                 })

        nb = path |> File.read!() |> Jason.decode!()
        cell = Enum.at(nb["cells"], 0)
        # outputs preserved from original
        assert cell["outputs"] == [%{"output_type" => "execute_result", "text" => ["DataFrame with 100 rows"]}]
      after
        File.rm(path)
      end
    end

    test "can change cell_type" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:ok, _} =
                 NotebookEdit.execute(%{
                   "action" => "edit_cell",
                   "path" => path,
                   "index" => 2,
                   "source" => "# Now markdown",
                   "cell_type" => "markdown"
                 })

        nb = path |> File.read!() |> Jason.decode!()
        assert Enum.at(nb["cells"], 2)["cell_type"] == "markdown"
      after
        File.rm(path)
      end
    end

    test "returns error for out-of-range index" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:error, msg} =
                 NotebookEdit.execute(%{
                   "action" => "edit_cell",
                   "path" => path,
                   "index" => 99,
                   "source" => "x"
                 })

        assert msg =~ "out of range"
      after
        File.rm(path)
      end
    end

    test "returns error when index is missing" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:error, msg} =
                 NotebookEdit.execute(%{
                   "action" => "edit_cell",
                   "path" => path,
                   "source" => "x"
                 })

        assert msg =~ "Missing required parameter: index"
      after
        File.rm(path)
      end
    end
  end

  # ── Delete cell action ──────────────────────────────────────────

  describe "delete_cell" do
    test "removes cell at given index" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:ok, msg} =
                 NotebookEdit.execute(%{
                   "action" => "delete_cell",
                   "path" => path,
                   "index" => 1
                 })

        assert msg =~ "Deleted cell [1]"
        assert msg =~ "2 cells remaining"

        nb = path |> File.read!() |> Jason.decode!()
        assert length(nb["cells"]) == 2
        # The markdown cell (formerly index 1) should be gone
        types = Enum.map(nb["cells"], & &1["cell_type"])
        assert types == ["code", "code"]
      after
        File.rm(path)
      end
    end

    test "returns error for out-of-range index" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:error, msg} =
                 NotebookEdit.execute(%{
                   "action" => "delete_cell",
                   "path" => path,
                   "index" => 10
                 })

        assert msg =~ "out of range"
      after
        File.rm(path)
      end
    end
  end

  # ── Move cell action ────────────────────────────────────────────

  describe "move_cell" do
    test "moves cell from index to position" do
      path = tmp_path()

      try do
        write_notebook(path)
        # Move cell 0 (code) to position 2
        assert {:ok, msg} =
                 NotebookEdit.execute(%{
                   "action" => "move_cell",
                   "path" => path,
                   "index" => 0,
                   "position" => 2
                 })

        assert msg =~ "Moved cell from [0] to [2]"

        nb = path |> File.read!() |> Jason.decode!()
        types = Enum.map(nb["cells"], & &1["cell_type"])
        # Original: [code, markdown, code] -> remove index 0 -> [markdown, code] -> insert at 2 -> [markdown, code, code]
        assert types == ["markdown", "code", "code"]
        # The moved cell should have the original source
        assert Enum.at(nb["cells"], 2)["source"] == ["import pandas as pd\n", "df = pd.read_csv(\"data.csv\")"]
      after
        File.rm(path)
      end
    end

    test "moves cell to beginning" do
      path = tmp_path()

      try do
        write_notebook(path)
        # Move last cell (index 2) to position 0
        assert {:ok, _} =
                 NotebookEdit.execute(%{
                   "action" => "move_cell",
                   "path" => path,
                   "index" => 2,
                   "position" => 0
                 })

        nb = path |> File.read!() |> Jason.decode!()
        first = Enum.at(nb["cells"], 0)
        assert first["source"] == ["print(\"hello\")"]
      after
        File.rm(path)
      end
    end

    test "returns error when position is missing" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:error, msg} =
                 NotebookEdit.execute(%{
                   "action" => "move_cell",
                   "path" => path,
                   "index" => 0
                 })

        assert msg =~ "Missing required parameter: position"
      after
        File.rm(path)
      end
    end

    test "returns error for out-of-range index" do
      path = tmp_path()

      try do
        write_notebook(path)

        assert {:error, msg} =
                 NotebookEdit.execute(%{
                   "action" => "move_cell",
                   "path" => path,
                   "index" => 99,
                   "position" => 0
                 })

        assert msg =~ "out of range"
      after
        File.rm(path)
      end
    end
  end

  # ── Edge cases ──────────────────────────────────────────────────

  describe "edge cases" do
    test "rejects non-.ipynb file" do
      assert {:error, msg} = NotebookEdit.execute(%{"action" => "read", "path" => "/tmp/file.txt"})
      assert msg =~ ".ipynb"
    end

    test "missing required parameters returns error" do
      assert {:error, msg} = NotebookEdit.execute(%{"path" => "/tmp/x.ipynb"})
      assert msg =~ "Missing required"
    end

    test "unknown action returns error" do
      path = tmp_path()

      try do
        write_notebook(path)
        assert {:error, msg} = NotebookEdit.execute(%{"action" => "unknown", "path" => path})
        assert msg =~ "Unknown action"
      after
        File.rm(path)
      end
    end

    test "notebook without cells key treated as empty" do
      path = tmp_path()

      try do
        File.write!(path, Jason.encode!(%{"nbformat" => 4, "metadata" => %{}}))
        assert {:ok, output} = NotebookEdit.execute(%{"action" => "read", "path" => path})
        assert output =~ "Empty notebook"
      after
        File.rm(path)
      end
    end

    test "handles error output type" do
      path = tmp_path()

      try do
        nb = %{
          "nbformat" => 4,
          "metadata" => %{},
          "cells" => [
            %{
              "cell_type" => "code",
              "source" => ["1/0"],
              "metadata" => %{},
              "outputs" => [%{"output_type" => "error", "ename" => "ZeroDivisionError", "evalue" => "division by zero"}]
            }
          ]
        }

        write_notebook(path, nb)
        assert {:ok, output} = NotebookEdit.execute(%{"action" => "read", "path" => path})
        assert output =~ "ZeroDivisionError"
      after
        File.rm(path)
      end
    end

    test "handles data output type" do
      path = tmp_path()

      try do
        nb = %{
          "nbformat" => 4,
          "metadata" => %{},
          "cells" => [
            %{
              "cell_type" => "code",
              "source" => ["plot()"],
              "metadata" => %{},
              "outputs" => [%{"output_type" => "display_data", "data" => %{"image/png" => "base64..."}}]
            }
          ]
        }

        write_notebook(path, nb)
        assert {:ok, output} = NotebookEdit.execute(%{"action" => "read", "path" => path})
        assert output =~ "data(image/png)"
      after
        File.rm(path)
      end
    end
  end

  # ── Security ────────────────────────────────────────────────────

  describe "security" do
    test "blocks reading from sensitive paths" do
      assert {:error, msg} = NotebookEdit.execute(%{"action" => "read", "path" => "~/.ssh/id_rsa.ipynb"})
      assert msg =~ "Access denied"
    end

    test "blocks writing to protected paths" do
      assert {:error, msg} =
               NotebookEdit.execute(%{
                 "action" => "add_cell",
                 "path" => "/usr/local/notebook.ipynb",
                 "source" => "x"
               })

      assert msg =~ "Access denied"
    end
  end
end
