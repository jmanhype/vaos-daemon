defmodule OptimalSystemAgent.Platform.GrantsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Platform.Schemas.Grant
  alias OptimalSystemAgent.Platform.Grants

  # Shared UUIDs used across tests
  @source_id Ecto.UUID.generate()
  @target_id Ecto.UUID.generate()
  @granter_id Ecto.UUID.generate()

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        source_os_id: @source_id,
        target_os_id: @target_id,
        granted_by: @granter_id,
        grant_type: "read"
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # Grant schema changeset (pure — no DB)
  # ---------------------------------------------------------------------------

  describe "Grant.changeset/2 — valid inputs" do
    test "accepts all valid grant_type values" do
      for type <- ~w(read write execute admin) do
        attrs = valid_attrs(%{grant_type: type})
        changeset = Grant.changeset(%Grant{}, attrs)
        assert changeset.valid?, "expected grant_type '#{type}' to be valid"
      end
    end

    test "accepts optional expires_at" do
      attrs = valid_attrs(%{expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)})
      changeset = Grant.changeset(%Grant{}, attrs)

      assert changeset.valid?
    end

    test "accepts optional resource_pattern" do
      attrs = valid_attrs(%{resource_pattern: "agents/*"})
      changeset = Grant.changeset(%Grant{}, attrs)

      assert changeset.valid?
    end
  end

  describe "Grant.changeset/2 — invalid inputs" do
    test "is invalid without source_os_id" do
      attrs = Map.delete(valid_attrs(), :source_os_id)
      changeset = Grant.changeset(%Grant{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :source_os_id)
    end

    test "is invalid without target_os_id" do
      attrs = Map.delete(valid_attrs(), :target_os_id)
      changeset = Grant.changeset(%Grant{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :target_os_id)
    end

    test "is invalid without granted_by" do
      attrs = Map.delete(valid_attrs(), :granted_by)
      changeset = Grant.changeset(%Grant{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :granted_by)
    end

    test "is invalid without grant_type" do
      attrs = Map.delete(valid_attrs(), :grant_type)
      changeset = Grant.changeset(%Grant{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :grant_type)
    end

    test "rejects unknown grant_type" do
      attrs = valid_attrs(%{grant_type: "own_everything"})
      changeset = Grant.changeset(%Grant{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :grant_type)
    end

    test "rejects self-grant (source == target)" do
      self_id = Ecto.UUID.generate()
      attrs = valid_attrs(%{source_os_id: self_id, target_os_id: self_id})
      changeset = Grant.changeset(%Grant{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :target_os_id)
      {msg, _} = Keyword.fetch!(changeset.errors, :target_os_id)
      assert msg =~ "same OS instance"
    end
  end

  # ---------------------------------------------------------------------------
  # Grants.create/1 — business logic validation (no DB for self-grant + expiry)
  # ---------------------------------------------------------------------------

  describe "create/1 — validation guards before Repo.insert" do
    test "returns error tuple with changeset when self-grant is attempted" do
      self_id = Ecto.UUID.generate()
      attrs = %{
        source_os_id: self_id,
        target_os_id: self_id,
        granted_by: @granter_id,
        grant_type: "read"
      }

      result = Grants.create(attrs)

      assert {:error, changeset} = result
      assert Keyword.has_key?(changeset.errors, :target_os_id)
    end

    test "returns error tuple when expires_at is in the past" do
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      attrs = valid_attrs(%{expires_at: past})

      result = Grants.create(attrs)

      assert {:error, changeset} = result
      assert Keyword.has_key?(changeset.errors, :expires_at)
    end

    test "allows nil expires_at (non-expiring grant)" do
      # No DB — this will attempt Repo.insert and fail; we assert it's NOT the
      # business-rule error (expiry or self-grant), proving the guard passes.
      attrs = valid_attrs(%{source_os_id: Ecto.UUID.generate(), target_os_id: Ecto.UUID.generate()})

      result =
        try do
          Grants.create(attrs)
        rescue
          RuntimeError -> {:db_error, :repo_not_started}
          _ -> {:db_error, :other}
        catch
          :exit, _ -> {:db_error, :exit}
        end

      # Should not be the expiry guard error — either Repo error or :ok
      refute match?({:error, %Ecto.Changeset{errors: [expires_at: _]}}, result)
    end

    test "expires_at in the future passes the expiry guard" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      attrs = valid_attrs(%{
        source_os_id: Ecto.UUID.generate(),
        target_os_id: Ecto.UUID.generate(),
        expires_at: future
      })

      result =
        try do
          Grants.create(attrs)
        rescue
          RuntimeError -> {:db_error, :repo_not_started}
          _ -> {:db_error, :other}
        catch
          :exit, _ -> {:db_error, :exit}
        end

      # Guard passes — result is Repo error (no DB), not our :expires_at guard
      refute match?({:error, %Ecto.Changeset{errors: [expires_at: _]}}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # Grant.changeset/2 — boundary and edge cases
  # ---------------------------------------------------------------------------

  describe "Grant.changeset/2 — edge cases" do
    test "distinct source and target IDs pass self-grant check" do
      changeset = Grant.changeset(%Grant{}, valid_attrs())
      assert changeset.valid?
    end

    test "handles nil grant_type gracefully (still invalid)" do
      attrs = valid_attrs(%{grant_type: nil})
      changeset = Grant.changeset(%Grant{}, attrs)

      refute changeset.valid?
    end

    test "resource_pattern is optional — changeset valid without it" do
      changeset = Grant.changeset(%Grant{}, valid_attrs())
      assert changeset.valid?
    end
  end
end
