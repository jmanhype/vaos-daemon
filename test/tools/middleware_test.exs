defmodule MiosaTools.MiddlewareTest do
  use ExUnit.Case, async: true

  alias MiosaTools.{Instruction, Middleware}

  # A simple executor that returns the instruction params
  defp success_executor(instruction) do
    {:ok, instruction.params}
  end

  defp failure_executor(instruction) do
    {:error, "tool #{instruction.tool} failed"}
  end

  # ---------------------------------------------------------------------------
  # Core middleware execution
  # ---------------------------------------------------------------------------

  describe "execute/3" do
    test "runs executor directly with empty stack" do
      inst = %Instruction{tool: "test_tool", params: %{"key" => "value"}}

      assert {:ok, %{"key" => "value"}} =
               Middleware.execute(inst, [], &success_executor/1)
    end

    test "runs middleware in stack order" do
      # Middleware that appends its name to a list in params
      defmodule FirstMW do
        @behaviour Middleware

        @impl true
        def call(instruction, next, _opts) do
          order = Map.get(instruction.params, :order, [])
          updated = %{instruction | params: Map.put(instruction.params, :order, order ++ [:first])}
          next.(updated)
        end
      end

      defmodule SecondMW do
        @behaviour Middleware

        @impl true
        def call(instruction, next, _opts) do
          order = Map.get(instruction.params, :order, [])
          updated = %{instruction | params: Map.put(instruction.params, :order, order ++ [:second])}
          next.(updated)
        end
      end

      inst = %Instruction{tool: "test", params: %{}}

      assert {:ok, result} =
               Middleware.execute(inst, [FirstMW, SecondMW], &success_executor/1)

      assert result[:order] == [:first, :second]
    end

    test "middleware can short-circuit execution" do
      defmodule BlockingMW do
        @behaviour Middleware

        @impl true
        def call(_instruction, _next, _opts) do
          {:error, "blocked by middleware"}
        end
      end

      inst = %Instruction{tool: "test", params: %{}}

      assert {:error, "blocked by middleware"} =
               Middleware.execute(inst, [BlockingMW], &success_executor/1)
    end

    test "middleware receives opts from tuple entry" do
      defmodule OptsMW do
        @behaviour Middleware

        @impl true
        def call(instruction, next, opts) do
          label = Keyword.get(opts, :label, "default")
          updated = %{instruction | params: Map.put(instruction.params, :label, label)}
          next.(updated)
        end
      end

      inst = %Instruction{tool: "test", params: %{}}

      assert {:ok, result} =
               Middleware.execute(inst, [{OptsMW, [label: "custom"]}], &success_executor/1)

      assert result[:label] == "custom"
    end

    test "middleware can transform the result" do
      defmodule TransformMW do
        @behaviour Middleware

        @impl true
        def call(instruction, next, _opts) do
          case next.(instruction) do
            {:ok, result} -> {:ok, Map.put(result, :transformed, true)}
            error -> error
          end
        end
      end

      inst = %Instruction{tool: "test", params: %{"x" => 1}}

      assert {:ok, result} =
               Middleware.execute(inst, [TransformMW], &success_executor/1)

      assert result[:transformed] == true
      assert result["x"] == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Built-in Middleware: Validation
  # ---------------------------------------------------------------------------

  describe "Middleware.Validation" do
    test "passes valid instructions through" do
      inst = %Instruction{tool: "test", params: %{"a" => 1}}

      assert {:ok, _} =
               Middleware.execute(inst, [Middleware.Validation], &success_executor/1)
    end

    test "rejects instruction with empty tool name" do
      inst = %Instruction{tool: "", params: %{}}

      assert {:error, msg} =
               Middleware.execute(inst, [Middleware.Validation], &success_executor/1)

      assert msg =~ "tool name is required"
    end
  end

  # ---------------------------------------------------------------------------
  # Built-in Middleware: Timing
  # ---------------------------------------------------------------------------

  describe "Middleware.Timing" do
    test "does not alter the result" do
      inst = %Instruction{tool: "test", params: %{"data" => "value"}}

      assert {:ok, %{"data" => "value"}} =
               Middleware.execute(inst, [Middleware.Timing], &success_executor/1)
    end

    test "passes through errors unchanged" do
      inst = %Instruction{tool: "test", params: %{}}

      assert {:error, _} =
               Middleware.execute(inst, [Middleware.Timing], &failure_executor/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Built-in Middleware: Logging
  # ---------------------------------------------------------------------------

  describe "Middleware.Logging" do
    test "does not alter success results" do
      inst = %Instruction{tool: "test", params: %{"x" => 1}}

      assert {:ok, %{"x" => 1}} =
               Middleware.execute(inst, [Middleware.Logging], &success_executor/1)
    end

    test "does not alter error results" do
      inst = %Instruction{tool: "test", params: %{}}

      assert {:error, "tool test failed"} =
               Middleware.execute(inst, [Middleware.Logging], &failure_executor/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Full stack integration
  # ---------------------------------------------------------------------------

  describe "full middleware stack" do
    test "composes Validation + Timing + Logging without interference" do
      inst = %Instruction{tool: "integration_test", params: %{"value" => 42}}

      stack = [
        Middleware.Validation,
        Middleware.Timing,
        Middleware.Logging
      ]

      assert {:ok, %{"value" => 42}} = Middleware.execute(inst, stack, &success_executor/1)
    end

    test "Validation short-circuits before Timing and Logging" do
      inst = %Instruction{tool: "", params: %{}}

      stack = [
        Middleware.Validation,
        Middleware.Timing,
        Middleware.Logging
      ]

      assert {:error, _} = Middleware.execute(inst, stack, &success_executor/1)
    end
  end
end
