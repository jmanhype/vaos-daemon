defmodule OptimalSystemAgent.Events.EventTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Events.Event

  describe "new/4" do
    test "creates event with all required fields" do
      event = Event.new(:tool_call, "agent:loop", %{tool: "grep"})

      assert is_binary(event.id)
      assert String.starts_with?(event.id, "evt_")
      assert event.type == :tool_call
      assert event.source == "agent:loop"
      assert %DateTime{} = event.time
      assert event.data == %{tool: "grep"}
    end

    test "sets optional fields from opts" do
      event =
        Event.new(:llm_response, "provider:anthropic", %{tokens: 100},
          parent_id: "evt_parent_123",
          session_id: "sess_abc",
          correlation_id: "corr_xyz",
          signal_mode: :code,
          signal_genre: :spec,
          signal_sn: 0.85
        )

      assert event.parent_id == "evt_parent_123"
      assert event.session_id == "sess_abc"
      assert event.correlation_id == "corr_xyz"
      assert event.signal_mode == :code
      assert event.signal_genre == :spec
      assert event.signal_sn == 0.85
    end

    test "defaults optional fields to nil" do
      event = Event.new(:system_event, "scheduler", %{})

      assert is_nil(event.parent_id)
      assert is_nil(event.session_id)
      assert is_nil(event.correlation_id)
      assert is_nil(event.signal_mode)
      assert is_nil(event.signal_genre)
      assert is_nil(event.signal_sn)
    end

    test "data defaults to nil when not provided" do
      event = Event.new(:user_message, "cli")
      assert is_nil(event.data)
    end

    test "sets CloudEvents specversion to 1.0.2" do
      event = Event.new(:test, "source", %{})
      assert event.specversion == "1.0.2"
    end

    test "defaults datacontenttype to application/json" do
      event = Event.new(:test, "source", %{})
      assert event.datacontenttype == "application/json"
    end

    test "defaults extensions to empty map" do
      event = Event.new(:test, "source", %{})
      assert event.extensions == %{}
    end

    test "sets new Signal Theory fields from opts" do
      event =
        Event.new(:test, "source", %{},
          signal_type: :direct,
          signal_format: :json,
          signal_structure: :specification,
          subject: "user:42",
          dataschema: "https://schema.example.com/v1",
          extensions: %{priority: :high}
        )

      assert event.signal_type == :direct
      assert event.signal_format == :json
      assert event.signal_structure == :specification
      assert event.subject == "user:42"
      assert event.dataschema == "https://schema.example.com/v1"
      assert event.extensions == %{priority: :high}
    end
  end

  describe "ID generation" do
    test "generates unique IDs" do
      ids = for _ <- 1..100, do: Event.new(:test, "test", %{}).id
      assert length(Enum.uniq(ids)) == 100
    end

    test "IDs are sortable by creation time" do
      e1 = Event.new(:test, "test", %{})
      Process.sleep(1)
      e2 = Event.new(:test, "test", %{})

      assert e1.id < e2.id
    end

    test "ID format includes timestamp and random suffix" do
      event = Event.new(:test, "test", %{})
      # Format: evt_{microsecond_timestamp}_{base64_random}
      parts = String.split(event.id, "_", parts: 3)
      assert length(parts) == 3
      assert hd(parts) == "evt"
    end
  end

  describe "child/5" do
    test "creates child event linked to parent" do
      parent = Event.new(:llm_request, "agent:loop", %{prompt: "hello"}, session_id: "sess_1")
      child = Event.child(parent, :llm_response, "provider:anthropic", %{text: "hi"})

      assert child.parent_id == parent.id
      assert child.session_id == parent.session_id
      # correlation_id defaults to parent.id when parent has no correlation_id
      assert child.correlation_id == parent.id
      assert child.type == :llm_response
      assert child.source == "provider:anthropic"
    end

    test "inherits parent correlation_id when set" do
      parent =
        Event.new(:llm_request, "agent:loop", %{},
          correlation_id: "corr_shared",
          session_id: "sess_1"
        )

      child = Event.child(parent, :tool_call, "agent:loop", %{})

      assert child.correlation_id == "corr_shared"
      assert child.parent_id == parent.id
    end

    test "child opts can override inherited fields" do
      parent = Event.new(:llm_request, "agent:loop", %{}, session_id: "sess_1")

      child =
        Event.child(parent, :tool_call, "agent:loop", %{},
          session_id: "sess_override",
          signal_mode: :code
        )

      assert child.session_id == "sess_override"
      assert child.signal_mode == :code
    end
  end

  describe "to_map/1" do
    test "converts struct to map without nil values" do
      event = Event.new(:tool_call, "agent:loop", %{tool: "grep"})
      map = Event.to_map(event)

      assert map.id == event.id
      assert map.type == :tool_call
      assert map.source == "agent:loop"
      assert map.data == %{tool: "grep"}
      assert %DateTime{} = map.time

      # nil fields should be excluded
      refute Map.has_key?(map, :parent_id)
      refute Map.has_key?(map, :session_id)
      refute Map.has_key?(map, :signal_mode)
    end

    test "includes all non-nil fields" do
      event =
        Event.new(:llm_response, "provider", %{},
          parent_id: "p1",
          signal_mode: :code,
          signal_sn: 0.9
        )

      map = Event.to_map(event)

      assert map.parent_id == "p1"
      assert map.signal_mode == :code
      assert map.signal_sn == 0.9
    end
  end

  describe "to_cloud_event/1" do
    test "serializes required CloudEvents fields" do
      event = Event.new(:tool_call, "agent:loop", %{tool: "grep"})
      ce = Event.to_cloud_event(event)

      assert ce["specversion"] == "1.0.2"
      assert ce["id"] == event.id
      assert ce["type"] == "tool_call"
      assert ce["source"] == "agent:loop"
      assert is_binary(ce["time"])
      assert ce["datacontenttype"] == "application/json"
    end

    test "includes data when present" do
      event = Event.new(:test, "src", %{key: "value"})
      ce = Event.to_cloud_event(event)

      assert ce["data"] == %{key: "value"}
    end

    test "excludes nil optional fields" do
      event = Event.new(:test, "src", %{})
      ce = Event.to_cloud_event(event)

      refute Map.has_key?(ce, "subject")
      refute Map.has_key?(ce, "dataschema")
      refute Map.has_key?(ce, "signal_mode")
      refute Map.has_key?(ce, "parent_id")
    end

    test "includes signal theory fields when set" do
      event =
        Event.new(:test, "src", %{},
          signal_mode: :code,
          signal_genre: :spec,
          signal_type: :inform,
          signal_format: :json,
          signal_structure: :specification,
          signal_sn: 0.85
        )

      ce = Event.to_cloud_event(event)

      assert ce["signal_mode"] == "code"
      assert ce["signal_genre"] == "spec"
      assert ce["signal_type"] == "inform"
      assert ce["signal_format"] == "json"
      assert ce["signal_structure"] == "specification"
      assert ce["signal_sn"] == 0.85
    end

    test "includes tracing fields when set" do
      event =
        Event.new(:test, "src", %{},
          parent_id: "p1",
          session_id: "s1",
          correlation_id: "c1"
        )

      ce = Event.to_cloud_event(event)

      assert ce["parent_id"] == "p1"
      assert ce["session_id"] == "s1"
      assert ce["correlation_id"] == "c1"
    end

    test "merges extensions with string keys" do
      event = Event.new(:test, "src", %{}, extensions: %{priority: :high, agent: "lead"})
      ce = Event.to_cloud_event(event)

      assert ce["priority"] == :high
      assert ce["agent"] == "lead"
    end
  end
end
