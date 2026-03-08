defmodule OptimalSystemAgent.Events.ClassifierTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Events.Event
  alias OptimalSystemAgent.Events.Classifier

  describe "classify/1" do
    test "returns all five dimensions" do
      event = Event.new(:tool_call, "agent:loop", %{tool: "grep"})
      result = Classifier.classify(event)

      assert Map.has_key?(result, :mode)
      assert Map.has_key?(result, :genre)
      assert Map.has_key?(result, :type)
      assert Map.has_key?(result, :format)
      assert Map.has_key?(result, :structure)
    end

    test "infers :code mode for map data" do
      event = Event.new(:tool_call, "agent:loop", %{tool: "grep"})
      result = Classifier.classify(event)

      assert result.mode == :code
    end

    test "infers :linguistic mode for nil data" do
      event = Event.new(:user_message, "cli")
      result = Classifier.classify(event)

      assert result.mode == :linguistic
    end

    test "infers :code mode for code-like string data" do
      event = Event.new(:tool_result, "tools", "defmodule Foo do\n  def bar, do: :ok\nend")
      result = Classifier.classify(event)

      assert result.mode == :code
    end

    test "infers :linguistic mode for plain string data" do
      event = Event.new(:user_message, "cli", "hello world")
      result = Classifier.classify(event)

      assert result.mode == :linguistic
    end
  end

  describe "genre inference" do
    test "infers :error genre from error type" do
      event = Event.new(:system_error, "scheduler", %{})
      result = Classifier.classify(event)

      assert result.genre == :error
    end

    test "infers :alert genre from alert type" do
      event = Event.new(:algedonic_alert, "monitor", %{})
      result = Classifier.classify(event)

      assert result.genre == :alert
    end

    test "infers :chat genre as default" do
      event = Event.new(:tool_call, "agent:loop", %{})
      result = Classifier.classify(event)

      assert result.genre == :chat
    end

    test "infers :brief genre from task type" do
      event = Event.new(:agent_task, "orchestrator", %{})
      result = Classifier.classify(event)

      assert result.genre == :brief
    end
  end

  describe "type (speech act) inference" do
    test "infers :inform for completed events" do
      event = Event.new(:task_completed, "worker", %{})
      result = Classifier.classify(event)

      assert result.type == :inform
    end

    test "infers :direct for request events" do
      event = Event.new(:tool_request, "agent", %{})
      result = Classifier.classify(event)

      assert result.type == :direct
    end

    test "infers :direct for dispatch events" do
      event = Event.new(:agent_dispatch, "orchestrator", %{})
      result = Classifier.classify(event)

      assert result.type == :direct
    end

    test "infers :commit for approved events" do
      event = Event.new(:change_approved, "reviewer", %{})
      result = Classifier.classify(event)

      assert result.type == :commit
    end

    test "infers :decide for decided events" do
      event = Event.new(:route_decided, "router", %{})
      result = Classifier.classify(event)

      assert result.type == :decide
    end

    test "defaults to :inform for unknown suffixes" do
      event = Event.new(:tool_call, "agent", %{})
      result = Classifier.classify(event)

      assert result.type == :inform
    end
  end

  describe "format inference" do
    test "infers :json for map data" do
      event = Event.new(:test, "src", %{key: "value"})
      result = Classifier.classify(event)

      assert result.format == :json
    end

    test "infers :json for list data" do
      event = Event.new(:test, "src", [1, 2, 3])
      result = Classifier.classify(event)

      assert result.format == :json
    end

    test "infers :code for code-like string" do
      event = Event.new(:test, "src", "fn x -> x + 1 end")
      result = Classifier.classify(event)

      assert result.format == :code
    end

    test "infers :markdown for markdown-like string" do
      event = Event.new(:test, "src", "# Heading\n\n- item 1\n- item 2")
      result = Classifier.classify(event)

      assert result.format == :markdown
    end

    test "infers :cli for plain text" do
      event = Event.new(:test, "src", "hello world")
      result = Classifier.classify(event)

      assert result.format == :cli
    end
  end

  describe "structure inference" do
    test "infers :error_report for error type" do
      event = Event.new(:system_error, "scheduler", %{})
      result = Classifier.classify(event)

      assert result.structure == :error_report
    end

    test "infers :default for unknown type" do
      event = Event.new(:tool_call, "agent", %{})
      result = Classifier.classify(event)

      assert result.structure == :default
    end
  end

  describe "auto_classify/1" do
    test "fills nil signal fields with inferred values" do
      event = Event.new(:tool_call, "agent:loop", %{tool: "grep"})

      assert is_nil(event.signal_mode)
      assert is_nil(event.signal_genre)

      classified = Classifier.auto_classify(event)

      assert classified.signal_mode == :code
      assert classified.signal_genre == :chat
      assert classified.signal_type == :inform
      assert classified.signal_format == :json
      assert classified.signal_structure == :default
      assert is_float(classified.signal_sn)
    end

    test "preserves explicit signal fields" do
      event =
        Event.new(:tool_call, "agent:loop", %{},
          signal_mode: :linguistic,
          signal_genre: :spec
        )

      classified = Classifier.auto_classify(event)

      # Explicit values preserved
      assert classified.signal_mode == :linguistic
      assert classified.signal_genre == :spec
      # Nil fields filled
      assert classified.signal_type == :inform
      assert classified.signal_format == :json
    end

    test "does not overwrite existing signal_sn" do
      event = Event.new(:test, "src", %{}, signal_sn: 0.99)
      classified = Classifier.auto_classify(event)

      assert classified.signal_sn == 0.99
    end
  end

  describe "sn_ratio/1" do
    test "returns float between 0.0 and 1.0" do
      event = Event.new(:tool_call, "agent:loop", %{tool: "grep"})
      ratio = Classifier.sn_ratio(event)

      assert is_float(ratio)
      assert ratio >= 0.0
      assert ratio <= 1.0
    end

    test "higher ratio for events with more context" do
      sparse = Event.new(:test, "src")

      rich =
        Event.new(:tool_call, "agent:loop", %{tool: "grep"},
          session_id: "sess_1",
          correlation_id: "corr_1",
          signal_mode: :code,
          signal_genre: :chat,
          signal_type: :inform,
          signal_format: :json,
          signal_structure: :default
        )

      assert Classifier.sn_ratio(rich) > Classifier.sn_ratio(sparse)
    end

    test "returns higher ratio for structured data" do
      empty = Event.new(:test, "src")
      with_data = Event.new(:test, "src", %{key: "value"})

      assert Classifier.sn_ratio(with_data) > Classifier.sn_ratio(empty)
    end
  end

  describe "code_like?/1" do
    test "detects Elixir code" do
      assert Classifier.code_like?("defmodule Foo do")
      assert Classifier.code_like?("def bar(x), do: x |> transform()")
      assert Classifier.code_like?("fn x -> x + 1 end")
    end

    test "detects JS code" do
      assert Classifier.code_like?("const foo = () => {}")
      assert Classifier.code_like?("let bar = function() {}")
      assert Classifier.code_like?("class MyComponent {}")
    end

    test "rejects plain text" do
      refute Classifier.code_like?("hello world")
      refute Classifier.code_like?("this is a normal sentence")
    end
  end
end
