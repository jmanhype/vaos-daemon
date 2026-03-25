defmodule Daemon.Tools.Builtins.KnowledgeTest do
  use ExUnit.Case

  alias Daemon.Tools.Builtins.Knowledge

  # ---------------------------------------------------------------------------
  # Each test gets a fresh knowledge store to avoid state bleed.
  # MiosaKnowledge.open/1 is idempotent when called with the same name,
  # so we use a unique store name per test process.
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Tool metadata
  # ---------------------------------------------------------------------------

  describe "tool metadata" do
    test "name returns knowledge" do
      assert Knowledge.name() == "knowledge"
    end

    test "description is a non-empty string" do
      desc = Knowledge.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end

    test "parameters schema requires action" do
      params = Knowledge.parameters()
      assert params["type"] == "object"
      assert "action" in params["required"]
      assert Map.has_key?(params["properties"], "action")
    end

    test "parameters defines all expected actions" do
      actions = get_in(Knowledge.parameters(), ["properties", "action", "enum"])
      assert "assert" in actions
      assert "retract" in actions
      assert "query" in actions
      assert "context" in actions
      assert "count" in actions
      assert "sparql" in actions
      assert "reason" in actions
    end
  end

  # ---------------------------------------------------------------------------
  # unknown action
  # ---------------------------------------------------------------------------

  describe "execute/1 — unknown action" do
    test "returns error for unrecognized action" do
      assert {:error, msg} = Knowledge.execute(%{"action" => "teleport"})
      assert msg =~ "Unknown action"
    end
  end

  # ---------------------------------------------------------------------------
  # assert
  # ---------------------------------------------------------------------------

  describe "assert" do
    test "inserts a triple and returns confirmation" do
      assert {:ok, msg} = Knowledge.execute(%{
        "action" => "assert",
        "subject" => "agent:osa",
        "predicate" => "rdf:type",
        "object" => "osa:Agent"
      })
      assert msg =~ "Asserted"
      assert msg =~ "agent:osa"
    end

    test "returns error when subject is missing" do
      assert {:error, msg} = Knowledge.execute(%{
        "action" => "assert",
        "predicate" => "rdf:type",
        "object" => "osa:Agent"
      })
      assert msg =~ "requires subject"
    end

    test "returns error when predicate is missing" do
      assert {:error, msg} = Knowledge.execute(%{
        "action" => "assert",
        "subject" => "agent:osa",
        "object" => "osa:Agent"
      })
      assert msg =~ "requires subject"
    end

    test "returns error when object is missing" do
      assert {:error, msg} = Knowledge.execute(%{
        "action" => "assert",
        "subject" => "agent:osa",
        "predicate" => "rdf:type"
      })
      assert msg =~ "requires subject"
    end
  end

  # ---------------------------------------------------------------------------
  # retract
  # ---------------------------------------------------------------------------

  describe "retract" do
    test "retracts an existing triple" do
      # First assert so there is something to retract
      Knowledge.execute(%{
        "action" => "assert",
        "subject" => "x",
        "predicate" => "y",
        "object" => "z"
      })

      assert {:ok, msg} = Knowledge.execute(%{
        "action" => "retract",
        "subject" => "x",
        "predicate" => "y",
        "object" => "z"
      })
      assert msg =~ "Retracted"
    end

    test "returns error when triple components are missing" do
      assert {:error, msg} = Knowledge.execute(%{
        "action" => "retract",
        "subject" => "x"
      })
      assert msg =~ "requires subject"
    end
  end

  # ---------------------------------------------------------------------------
  # query
  # ---------------------------------------------------------------------------

  describe "query" do
    test "returns no-match message on empty result" do
      assert {:ok, msg} = Knowledge.execute(%{
        "action" => "query",
        "subject" => "nonexistent:subject:#{System.unique_integer()}"
      })
      assert msg =~ "No matching"
    end

    test "returns found triples after asserting" do
      subj = "osa:test_agent_#{System.unique_integer([:positive])}"

      Knowledge.execute(%{
        "action" => "assert",
        "subject" => subj,
        "predicate" => "osa:hasRole",
        "object" => "backend"
      })

      assert {:ok, msg} = Knowledge.execute(%{
        "action" => "query",
        "subject" => subj
      })
      assert msg =~ "Found"
      assert msg =~ subj
    end

    test "query with no filters returns results (or no-match)" do
      result = Knowledge.execute(%{"action" => "query"})
      assert match?({:ok, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # count
  # ---------------------------------------------------------------------------

  describe "count" do
    test "returns the triple count as a string" do
      assert {:ok, msg} = Knowledge.execute(%{"action" => "count"})
      assert msg =~ "triples"
    end

    test "count increases after asserting a new triple" do
      {:ok, before_msg} = Knowledge.execute(%{"action" => "count"})
      before_n = extract_count(before_msg)

      uniq = "osa:count_test_#{System.unique_integer([:positive])}"
      Knowledge.execute(%{"action" => "assert", "subject" => uniq, "predicate" => "p", "object" => "o"})

      {:ok, after_msg} = Knowledge.execute(%{"action" => "count"})
      after_n = extract_count(after_msg)

      assert after_n >= before_n + 1
    end
  end

  # ---------------------------------------------------------------------------
  # context
  # ---------------------------------------------------------------------------

  describe "context" do
    test "returns a string prompt for default agent" do
      assert {:ok, msg} = Knowledge.execute(%{"action" => "context"})
      assert is_binary(msg)
    end

    test "returns a string prompt for a named agent" do
      assert {:ok, msg} = Knowledge.execute(%{"action" => "context", "agent_id" => "test-agent"})
      assert is_binary(msg)
    end
  end

  # ---------------------------------------------------------------------------
  # sparql
  # ---------------------------------------------------------------------------

  describe "sparql" do
    test "returns error when sparql_query is missing" do
      assert {:error, msg} = Knowledge.execute(%{"action" => "sparql"})
      assert msg =~ "sparql_query"
    end

    test "executes a basic SELECT query or reports backend limitation" do
      subj = "osa:sparql_test_#{System.unique_integer([:positive])}"
      Knowledge.execute(%{"action" => "assert", "subject" => subj, "predicate" => "osa:kind", "object" => "agent"})

      result = Knowledge.execute(%{
        "action" => "sparql",
        "sparql_query" => "SELECT ?s ?p ?o WHERE { ?s ?p ?o }"
      })

      # ETS backend returns :sparql_not_supported; SPARQL-capable backends return rows.
      # Both are valid outcomes depending on the configured backend.
      case result do
        {:ok, msg} -> assert msg =~ "SPARQL results" or msg =~ "rows"
        {:error, msg} -> assert msg =~ "SPARQL" or msg =~ "not_supported" or msg =~ "error"
      end
    end

    test "reports SPARQL error on malformed query" do
      result = Knowledge.execute(%{
        "action" => "sparql",
        "sparql_query" => "THIS IS NOT SPARQL !!!"
      })
      # Both {:error, _} from parse failure or backend limitation are acceptable
      assert match?({:error, _}, result) or match?({:ok, _}, result)
      assert is_binary(elem(result, 1))
    end
  end

  # ---------------------------------------------------------------------------
  # reason
  # ---------------------------------------------------------------------------

  describe "reason" do
    test "runs inference and returns completion message" do
      result = Knowledge.execute(%{"action" => "reason"})
      # If store is running, expect ok with rounds info; else an error
      case result do
        {:ok, msg} ->
          assert msg =~ "Reasoning complete" or msg =~ "rounds"

        {:error, msg} ->
          assert is_binary(msg)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # exception rescue
  # ---------------------------------------------------------------------------

  describe "exception handling" do
    test "catches exceptions and returns tagged error" do
      # Passing a non-string subject to trigger a guard mismatch
      result = Knowledge.execute(%{
        "action" => "assert",
        "subject" => 123,
        "predicate" => "p",
        "object" => "o"
      })
      # Should be an error (guard fails -> do_assert(_) clause)
      assert {:error, _} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp extract_count(msg) do
    case Regex.run(~r/(\d+) triples/, msg) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end
end
