defmodule Backplane.Auth.RBACTest do
  use Backplane.Auth.DataCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Auth
  alias Backplane.Auth.Schemas.{Role, RoleScope, UserRole}

  describe "roles and scopes" do
    test "creates roles and assigns scopes" do
      scope!("gsmlg:read")

      assert {:ok, %Role{} = role} =
               Auth.RBAC.create_role(%{name: "reader", label: "Reader"})

      assert {:ok, %RoleScope{} = role_scope} =
               Auth.RBAC.assign_role_scope(role, "gsmlg:read")

      assert role_scope.role_id == role.id
      assert role_scope.scope_name == "gsmlg:read"

      assert [%Role{name: "reader", role_scopes: [%RoleScope{scope_name: "gsmlg:read"}]}] =
               Auth.RBAC.list_roles()
    end

    test "assigns roles to users and computes effective scopes as a union" do
      user = auth_user_fixture!()
      scope!("gsmlg:read")
      scope!("gsmlg:write")

      assert {:ok, reader} = Auth.RBAC.create_role(%{name: "reader", label: "Reader"})
      assert {:ok, writer} = Auth.RBAC.create_role(%{name: "writer", label: "Writer"})
      assert {:ok, _role_scope} = Auth.RBAC.assign_role_scope(reader, "gsmlg:read")
      assert {:ok, _role_scope} = Auth.RBAC.assign_role_scope(writer, "gsmlg:read")
      assert {:ok, _role_scope} = Auth.RBAC.assign_role_scope(writer, "gsmlg:write")

      assert {:ok, %UserRole{}} = Auth.RBAC.assign_user_role(user, reader)
      assert {:ok, %UserRole{}} = Auth.RBAC.assign_user_role(user, writer)

      assert ["gsmlg:read", "gsmlg:write"] = Auth.RBAC.effective_scope_names(user)

      assert user_roles = Auth.RBAC.list_user_roles()
      assert Enum.any?(user_roles, &(&1.user.email == user.email and &1.role.name == "reader"))
      assert Enum.any?(user_roles, &(&1.user.email == user.email and &1.role.name == "writer"))
    end

    test "validates requested scopes against the user's effective scopes" do
      user = auth_user_fixture!()
      scope!("gsmlg:read")
      scope!("gsmlg:write")

      assert {:ok, reader} = Auth.RBAC.create_role(%{name: "reader", label: "Reader"})
      assert {:ok, _role_scope} = Auth.RBAC.assign_role_scope(reader, "gsmlg:read")
      assert {:ok, %UserRole{}} = Auth.RBAC.assign_user_role(user, reader)

      assert :ok = Auth.RBAC.validate_user_scopes(user, "gsmlg:read")
      assert :ok = Auth.RBAC.validate_user_scopes(user, "")
      assert {:error, :invalid_scope} = Auth.RBAC.validate_user_scopes(user, "gsmlg:write")

      assert {:error, :invalid_scope} =
               Auth.RBAC.validate_user_scopes(user, "gsmlg:read gsmlg:write")
    end

    test "system roles are seeded and cannot be deleted" do
      assert :ok = Auth.RBAC.seed_system_roles()

      role = Auth.RBAC.get_role("admin")
      assert %Role{name: "admin", system: true} = role
      assert {:error, :system_role} = Auth.RBAC.delete_role(role)
    end
  end

  defp scope!(name) do
    assert {:ok, scope} = Auth.OAuth.create_scope(%{name: name, label: name, public: true})
    scope
  end
end
