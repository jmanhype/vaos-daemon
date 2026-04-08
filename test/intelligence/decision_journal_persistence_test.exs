defmodule Daemon.Intelligence.DecisionJournalPersistenceTest do
  use ExUnit.Case, async: false

  @journal_path Path.expand("~/.daemon/intelligence/decision_journal.json")

  setup do
    original =
      case File.read(@journal_path) do
        {:ok, content} -> {:present, content}
        {:error, _} -> :missing
      end

    on_exit(fn ->
      case original do
        {:present, content} ->
          File.mkdir_p!(Path.dirname(@journal_path))
          File.write!(@journal_path, content)

        :missing ->
          File.rm(@journal_path)
      end
    end)

    :ok
  end

  test "init clears legacy in-flight investigate entries that used n/a branch" do
    File.mkdir_p!(Path.dirname(@journal_path))

    File.write!(
      @journal_path,
      Jason.encode!(%{
        "version" => 1,
        "decisions" => [
          %{
            "action_type" => "investigate",
            "branch" => "n/a",
            "claim_id" => "claim_test",
            "completed_at" => nil,
            "normalized_topic" => "does caffeine impair sleep quality",
            "outcome" => nil,
            "proposed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "source_module" => "investigation",
            "status" => "in_flight",
            "topic" => "Does caffeine impair sleep quality?"
          }
        ],
        "stats" => %{},
        "version" => 1
      })
    )

    assert {:ok, state} = Daemon.Intelligence.DecisionJournal.init([])
    assert state.in_flight == %{}

    assert [
             %{
               status: :cleared,
               outcome: :cleared,
               branch: "n/a",
               action_type: :investigate
             }
           ] = state.decisions
  end
end
