defmodule Backplane.Auth.ResourceOwnersTest do
  use Backplane.Auth.DataCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Auth
  alias Backplane.Auth.ResourceOwners
  alias Boruta.Oauth.{ResourceOwner, Scope}

  @password "correct horse battery staple"

  test "loads active users as Boruta resource owners" do
    user = auth_user_fixture!(email: "alice@example.com", name: "Alice", password: @password)

    assert {:ok, %ResourceOwner{} = owner} = ResourceOwners.get_by(sub: user.id)
    assert owner.sub == user.id
    assert owner.username == "alice@example.com"
    assert owner.extra_claims["email"] == "alice@example.com"
    assert owner.extra_claims["name"] == "Alice"
  end

  test "rejects inactive users" do
    user = auth_user_fixture!(email: "alice@example.com", password: @password)
    assert {:ok, inactive} = Auth.Accounts.disable_user(user)

    assert {:error, "resource owner is inactive"} = ResourceOwners.get_by(sub: inactive.id)
  end

  test "returns effective role scopes as Boruta OAuth scopes" do
    user = auth_user_fixture!(email: "alice@example.com", password: @password)
    scope!("openid")
    scope!("gsmlg:read")
    assert {:ok, role} = Auth.RBAC.create_role(%{name: "reader", label: "Reader"})
    assert {:ok, _role_scope} = Auth.RBAC.assign_role_scope(role, "openid")
    assert {:ok, _role_scope} = Auth.RBAC.assign_role_scope(role, "gsmlg:read")
    assert {:ok, _user_role} = Auth.RBAC.assign_user_role(user, role)

    assert {:ok, owner} = ResourceOwners.get_by(sub: user.id)
    scopes = ResourceOwners.authorized_scopes(owner)

    assert [%Scope{}, %Scope{}] = scopes
    assert ["gsmlg:read", "openid"] = scopes |> Enum.map(& &1.name) |> Enum.sort()
  end

  test "returns stable OIDC claims" do
    user = auth_user_fixture!(email: "alice@example.com", name: "Alice", password: @password)

    assert {:ok, owner} = ResourceOwners.get_by(sub: user.id)

    assert %{"email" => "alice@example.com", "name" => "Alice", "email_verified" => true} =
             ResourceOwners.claims(owner, "openid email profile")
  end

  defp scope!(name) do
    assert {:ok, scope} = Auth.OAuth.create_scope(%{name: name, label: name, public: true})
    scope
  end
end
