defmodule Backplane.Auth.Schemas.RoleScope do
  @moduledoc "Scope granted by a Backplane Auth role."

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Auth.Schemas.Role

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "auth_role_scopes" do
    field :scope_name, :string

    belongs_to :role, Role

    timestamps()
  end

  def changeset(role_scope, attrs) do
    role_scope
    |> cast(attrs, [:role_id, :scope_name])
    |> update_change(:scope_name, &normalize_scope/1)
    |> validate_required([:role_id, :scope_name])
    |> foreign_key_constraint(:role_id)
    |> unique_constraint([:role_id, :scope_name])
  end

  defp normalize_scope(scope) when is_binary(scope), do: String.trim(scope)
  defp normalize_scope(scope), do: scope
end
