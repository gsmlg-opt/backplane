defmodule Backplane.Auth.RBAC do
  @moduledoc "Role and effective-scope management for Backplane Auth users."

  import Ecto.Query

  alias Backplane.Auth.OAuth
  alias Backplane.Auth.Schemas.{Role, RoleScope, User, UserRole}
  alias Backplane.Repo

  @system_roles [
    %{name: "admin", label: "Admin", system: true},
    %{name: "member", label: "Member", system: true},
    %{name: "viewer", label: "Viewer", system: true}
  ]

  def create_role(attrs) when is_map(attrs) do
    %Role{}
    |> Role.changeset(attrs)
    |> Repo.insert()
  end

  def get_role(name) when is_binary(name) do
    Repo.get_by(Role, name: name |> String.trim() |> String.downcase())
  end

  def delete_role(%Role{system: true}), do: {:error, :system_role}
  def delete_role(%Role{} = role), do: Repo.delete(role)

  def assign_role_scope(%Role{id: role_id}, scope_name) when is_binary(scope_name) do
    scope_name = String.trim(scope_name)

    case OAuth.get_scope(scope_name) do
      nil ->
        {:error, :unknown_scope}

      _scope ->
        case Repo.get_by(RoleScope, role_id: role_id, scope_name: scope_name) do
          %RoleScope{} = role_scope ->
            {:ok, role_scope}

          nil ->
            %RoleScope{}
            |> RoleScope.changeset(%{role_id: role_id, scope_name: scope_name})
            |> Repo.insert()
        end
    end
  end

  def assign_user_role(%User{id: user_id}, %Role{id: role_id}) do
    case Repo.get_by(UserRole, user_id: user_id, role_id: role_id) do
      %UserRole{} = user_role ->
        {:ok, user_role}

      nil ->
        %UserRole{}
        |> UserRole.changeset(%{user_id: user_id, role_id: role_id})
        |> Repo.insert()
    end
  end

  def revoke_user_role(%User{id: user_id}, %Role{id: role_id}) do
    case Repo.get_by(UserRole, user_id: user_id, role_id: role_id) do
      %UserRole{} = user_role -> Repo.delete(user_role)
      nil -> {:error, :not_found}
    end
  end

  def effective_scope_names(%User{id: user_id}) do
    RoleScope
    |> join(:inner, [role_scope], user_role in UserRole,
      on: user_role.role_id == role_scope.role_id
    )
    |> where([_role_scope, user_role], user_role.user_id == ^user_id)
    |> select([role_scope], role_scope.scope_name)
    |> distinct(true)
    |> order_by([role_scope], role_scope.scope_name)
    |> Repo.all()
  end

  def seed_system_roles do
    Enum.each(@system_roles, fn attrs ->
      case get_role(attrs.name) do
        nil -> create_role(attrs)
        %Role{} -> :ok
      end
    end)

    :ok
  end
end
