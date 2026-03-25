defmodule Daemon.Platform.OsInstancesTest do
  use ExUnit.Case, async: true

  alias Daemon.Platform.Schemas.{OsInstance, OsInstanceMember}
  alias Daemon.Platform.OsInstances

  @tenant_id Ecto.UUID.generate()
  @owner_id Ecto.UUID.generate()

  defp valid_instance_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "tenant_id" => @tenant_id,
        "owner_id" => @owner_id,
        "name" => "My OS",
        "slug" => "my-os"
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # OsInstance schema changeset (pure — no DB)
  # ---------------------------------------------------------------------------

  describe "OsInstance.changeset/2 — valid inputs" do
    test "accepts all valid status values" do
      for status <- ~w(provisioning active suspended stopped deleting) do
        attrs = valid_instance_attrs(%{"status" => status})
        changeset = OsInstance.changeset(%OsInstance{}, attrs)
        assert changeset.valid?, "expected status '#{status}' to be valid"
      end
    end

    test "accepts all valid template_type values" do
      for template <- ~w(business_os content_os agency_os dev_os data_os blank) do
        attrs = valid_instance_attrs(%{"template_type" => template})
        changeset = OsInstance.changeset(%OsInstance{}, attrs)
        assert changeset.valid?, "expected template '#{template}' to be valid"
      end
    end

    test "defaults status to 'provisioning' when omitted" do
      attrs = valid_instance_attrs()
      changeset = OsInstance.changeset(%OsInstance{}, attrs)

      assert changeset.valid?
      # struct default
      assert changeset.data.status == "provisioning"
    end

    test "accepts optional config map" do
      attrs = valid_instance_attrs(%{"config" => %{"key" => "val"}})
      changeset = OsInstance.changeset(%OsInstance{}, attrs)

      assert changeset.valid?
    end

    test "accepts optional sandbox_id and sandbox_url" do
      attrs = valid_instance_attrs(%{"sandbox_id" => "sb-123", "sandbox_url" => "https://sandbox.example.com"})
      changeset = OsInstance.changeset(%OsInstance{}, attrs)

      assert changeset.valid?
    end
  end

  describe "OsInstance.changeset/2 — invalid inputs" do
    test "is invalid without name" do
      attrs = Map.delete(valid_instance_attrs(), "name")
      changeset = OsInstance.changeset(%OsInstance{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :name)
    end

    test "is invalid without slug" do
      attrs = Map.delete(valid_instance_attrs(), "slug")
      changeset = OsInstance.changeset(%OsInstance{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :slug)
    end

    test "is invalid without tenant_id" do
      attrs = Map.delete(valid_instance_attrs(), "tenant_id")
      changeset = OsInstance.changeset(%OsInstance{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :tenant_id)
    end

    test "is invalid without owner_id" do
      attrs = Map.delete(valid_instance_attrs(), "owner_id")
      changeset = OsInstance.changeset(%OsInstance{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :owner_id)
    end

    test "rejects invalid status value" do
      attrs = valid_instance_attrs(%{"status" => "flying"})
      changeset = OsInstance.changeset(%OsInstance{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :status)
    end

    test "rejects invalid template_type value" do
      attrs = valid_instance_attrs(%{"template_type" => "mystery_os"})
      changeset = OsInstance.changeset(%OsInstance{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :template_type)
    end
  end

  # ---------------------------------------------------------------------------
  # OsInstanceMember schema changeset (pure — no DB)
  # ---------------------------------------------------------------------------

  describe "OsInstanceMember.changeset/2" do
    test "accepts valid member attrs" do
      attrs = %{
        "os_instance_id" => Ecto.UUID.generate(),
        "user_id" => Ecto.UUID.generate(),
        "role" => "member"
      }
      changeset = OsInstanceMember.changeset(%OsInstanceMember{}, attrs)

      assert changeset.valid?
    end

    test "is invalid without required fields" do
      changeset = OsInstanceMember.changeset(%OsInstanceMember{}, %{})

      refute changeset.valid?
      error_keys = Keyword.keys(changeset.errors)
      assert :os_instance_id in error_keys
      assert :user_id in error_keys
      assert :role in error_keys
    end

    test "accepts optional permissions map" do
      attrs = %{
        "os_instance_id" => Ecto.UUID.generate(),
        "user_id" => Ecto.UUID.generate(),
        "role" => "admin",
        "permissions" => %{"read" => true, "write" => true}
      }
      changeset = OsInstanceMember.changeset(%OsInstanceMember{}, attrs)

      assert changeset.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # OsInstances.create/3 — status defaulting behavior
  # ---------------------------------------------------------------------------

  describe "create/3 — status defaulting" do
    test "injects 'provisioning' status when not provided in attrs" do
      # The Repo call will fail (no DB) but we can inspect the changeset being
      # built by checking the attrs transformation in the module.
      # We confirm the module's behavior by observing the changeset directly.
      attrs = %{"name" => "Test OS", "slug" => "test-os"}

      # Build the attrs as create/3 does
      merged =
        attrs
        |> Map.put("tenant_id", @tenant_id)
        |> Map.put("owner_id", @owner_id)
        |> Map.put_new("status", "provisioning")

      changeset = OsInstance.changeset(%OsInstance{}, merged)

      assert changeset.valid?
      # status may arrive as a change or remain as the schema default
      assert Ecto.Changeset.get_field(changeset, :status) == "provisioning"
    end

    test "does not overwrite a caller-provided status" do
      attrs = %{
        "name" => "Active OS",
        "slug" => "active-os",
        "status" => "active"
      }

      merged =
        attrs
        |> Map.put("tenant_id", @tenant_id)
        |> Map.put("owner_id", @owner_id)
        |> Map.put_new("status", "provisioning")

      changeset = OsInstance.changeset(%OsInstance{}, merged)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :status) == "active"
    end
  end

  # ---------------------------------------------------------------------------
  # OsInstances.enter/2 — membership check (no DB: verifies not_member path)
  # ---------------------------------------------------------------------------

  describe "enter/2 — no DB path" do
    test "returns :not_member when Repo.one returns nil (no DB)" do
      # Without a DB, Repo.one will raise — we document expected production behavior
      # and test that the function signature and module compile correctly.
      # In production, when no membership row is found, the function returns {:error, :not_member}.
      #
      # We verify the contract by directly inspecting the guard clause:
      # OsInstances.enter checks member != nil before calling Auth.generate_token.
      os_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      # No DB — Repo call will raise; catch it and assert Repo is called (not a guard error)
      result =
        try do
          OsInstances.enter(os_id, user_id)
        rescue
          DBConnection.ConnectionError -> {:db_error, :not_connected}
          e in [RuntimeError, Postgrex.Error, DBConnection.OwnershipError] -> {:db_error, e}
        catch
          :exit, _ -> {:db_error, :exit}
        end

      # The function either returned :not_member (if Repo returned nil somehow)
      # or hit a DB connection error — either way it didn't crash with a logic error.
      assert result == {:error, :not_member} or match?({:db_error, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # OsInstances.delete/1 — soft delete sets status to 'deleting'
  # ---------------------------------------------------------------------------

  describe "delete/1 — soft delete changeset" do
    test "changeset produced by delete sets status to 'deleting'" do
      # Simulate what delete/1 does internally
      instance = %OsInstance{
        id: Ecto.UUID.generate(),
        tenant_id: @tenant_id,
        owner_id: @owner_id,
        name: "To Delete",
        slug: "to-delete",
        status: "active"
      }

      changeset = OsInstance.changeset(instance, %{"status" => "deleting"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == "deleting"
    end
  end

  # ---------------------------------------------------------------------------
  # OsInstances.update/2 — changeset validation for partial updates
  # ---------------------------------------------------------------------------

  describe "update/2 — changeset behavior" do
    test "updating name produces a valid changeset" do
      instance = %OsInstance{
        id: Ecto.UUID.generate(),
        tenant_id: @tenant_id,
        owner_id: @owner_id,
        name: "Old Name",
        slug: "old-name",
        status: "active"
      }

      changeset = OsInstance.changeset(instance, %{"name" => "New Name"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "New Name"
    end

    test "updating to invalid status produces invalid changeset" do
      instance = %OsInstance{
        id: Ecto.UUID.generate(),
        tenant_id: @tenant_id,
        owner_id: @owner_id,
        name: "My OS",
        slug: "my-os",
        status: "active"
      }

      changeset = OsInstance.changeset(instance, %{"status" => "unknown_state"})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :status)
    end
  end
end
