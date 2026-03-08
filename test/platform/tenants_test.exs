defmodule OptimalSystemAgent.Platform.TenantsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Platform.Schemas.{Tenant, TenantMember, TenantInvite}
  alias OptimalSystemAgent.Platform.Tenants

  # ---------------------------------------------------------------------------
  # Tenant schema changeset (pure — no DB)
  # ---------------------------------------------------------------------------

  describe "Tenant.changeset/2 — valid inputs" do
    test "accepts valid attrs and is valid" do
      attrs = %{name: "Acme Corp", slug: "acme-corp", owner_id: Ecto.UUID.generate()}
      changeset = Tenant.changeset(%Tenant{}, attrs)

      assert changeset.valid?
    end

    test "accepts all valid plan values" do
      valid_plans = ~w(free starter pro enterprise)
      owner_id = Ecto.UUID.generate()

      for plan <- valid_plans do
        attrs = %{name: "Org", slug: "org-#{plan}", plan: plan, owner_id: owner_id}
        changeset = Tenant.changeset(%Tenant{}, attrs)
        assert changeset.valid?, "expected plan #{plan} to be valid"
      end
    end

    test "defaults plan to 'free' when omitted" do
      attrs = %{name: "No Plan Corp", slug: "no-plan"}
      changeset = Tenant.changeset(%Tenant{}, attrs)

      # default is set on the schema, not the changeset — check struct default
      assert %Tenant{plan: "free"} = changeset.data
    end
  end

  describe "Tenant.changeset/2 — invalid inputs" do
    test "is invalid without name" do
      changeset = Tenant.changeset(%Tenant{}, %{slug: "no-name"})

      refute changeset.valid?
      assert {:name, _} = hd(changeset.errors)
    end

    test "is invalid without slug" do
      changeset = Tenant.changeset(%Tenant{}, %{name: "No Slug Corp"})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :slug)
    end

    test "rejects slug with uppercase letters" do
      attrs = %{name: "Bad Slug", slug: "BadSlug"}
      changeset = Tenant.changeset(%Tenant{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :slug)
    end

    test "rejects slug with spaces" do
      attrs = %{name: "Bad Slug", slug: "bad slug"}
      changeset = Tenant.changeset(%Tenant{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :slug)
    end

    test "rejects invalid plan value" do
      attrs = %{name: "Bad Plan", slug: "bad-plan", plan: "super-ultra"}
      changeset = Tenant.changeset(%Tenant{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :plan)
    end

    test "rejects name longer than 255 characters" do
      long_name = String.duplicate("a", 256)
      attrs = %{name: long_name, slug: "overflow"}
      changeset = Tenant.changeset(%Tenant{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :name)
    end

    test "rejects slug longer than 100 characters" do
      long_slug = String.duplicate("a", 101)
      attrs = %{name: "Long Slug", slug: long_slug}
      changeset = Tenant.changeset(%Tenant{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :slug)
    end
  end

  # ---------------------------------------------------------------------------
  # TenantMember schema changeset (pure — no DB)
  # ---------------------------------------------------------------------------

  describe "TenantMember.changeset/2" do
    test "accepts valid owner/admin/member roles" do
      for role <- ~w(owner admin member) do
        attrs = %{
          tenant_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          role: role,
          joined_at: DateTime.utc_now()
        }
        changeset = TenantMember.changeset(%TenantMember{}, attrs)
        assert changeset.valid?, "expected role #{role} to be valid"
      end
    end

    test "rejects invalid role" do
      attrs = %{tenant_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate(), role: "superuser"}
      changeset = TenantMember.changeset(%TenantMember{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :role)
    end

    test "is invalid without required fields" do
      changeset = TenantMember.changeset(%TenantMember{}, %{})

      refute changeset.valid?
      error_keys = Keyword.keys(changeset.errors)
      assert :tenant_id in error_keys
      assert :user_id in error_keys
      assert :role in error_keys
    end
  end

  # ---------------------------------------------------------------------------
  # TenantInvite schema changeset (pure — no DB)
  # ---------------------------------------------------------------------------

  describe "TenantInvite.changeset/2" do
    test "accepts valid invite attrs" do
      attrs = %{
        tenant_id: Ecto.UUID.generate(),
        email: "invitee@example.com",
        role: "member",
        expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
      }
      changeset = TenantInvite.changeset(%TenantInvite{}, attrs)

      assert changeset.valid?
    end

    test "auto-generates a token when none is provided" do
      attrs = %{
        tenant_id: Ecto.UUID.generate(),
        email: "auto-token@example.com",
        role: "member"
      }
      changeset = TenantInvite.changeset(%TenantInvite{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :token) != nil
    end

    test "preserves existing token when provided" do
      existing_token = "my-custom-token"
      attrs = %{
        tenant_id: Ecto.UUID.generate(),
        email: "token@example.com",
        role: "member",
        token: existing_token
      }
      changeset = TenantInvite.changeset(%TenantInvite{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :token) == existing_token
    end

    test "rejects invalid email format" do
      attrs = %{tenant_id: Ecto.UUID.generate(), email: "not-an-email", role: "member"}
      changeset = TenantInvite.changeset(%TenantInvite{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :email)
    end

    test "is invalid without required fields" do
      changeset = TenantInvite.changeset(%TenantInvite{}, %{})

      refute changeset.valid?
      error_keys = Keyword.keys(changeset.errors)
      assert :tenant_id in error_keys
      assert :email in error_keys
      assert :role in error_keys
    end
  end

  # ---------------------------------------------------------------------------
  # update_member_role/3 — pure role validation logic (no DB hit on invalid role)
  # ---------------------------------------------------------------------------

  describe "update_member_role/3 — role validation" do
    test "returns error immediately for invalid role without DB call" do
      # When the role is invalid the function short-circuits before any Repo call
      result = Tenants.update_member_role(Ecto.UUID.generate(), Ecto.UUID.generate(), "superadmin")

      assert {:error, :invalid_role} = result
    end

    test "returns error for empty string role" do
      result = Tenants.update_member_role(Ecto.UUID.generate(), Ecto.UUID.generate(), "")

      assert {:error, :invalid_role} = result
    end

    test "valid roles do not immediately return :invalid_role error" do
      # For valid roles the function proceeds to the Repo (which will fail since
      # there is no DB in unit tests — we only verify the role guard passes).
      # We catch the Repo error rather than :invalid_role.
      for role <- ~w(owner admin member) do
        result =
          try do
            Tenants.update_member_role(Ecto.UUID.generate(), Ecto.UUID.generate(), role)
          rescue
            RuntimeError -> {:db_error, :repo_not_started}
            _ -> {:db_error, :other}
          catch
            :exit, _ -> {:db_error, :exit}
          end

        refute result == {:error, :invalid_role},
          "role '#{role}' should pass the role guard but got :invalid_role"
      end
    end
  end
end
