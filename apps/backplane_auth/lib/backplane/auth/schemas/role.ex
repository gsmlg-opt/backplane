defmodule Backplane.Auth.Schemas.Role do
  @moduledoc "Reusable role that grants Backplane Auth OAuth scopes."

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Auth.Schemas.{RoleScope, UserRole}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "auth_roles" do
    field :name, :string
    field :label, :string
    field :description, :string
    field :system, :boolean, default: false
    field :metadata, :map, default: %{}

    has_many :role_scopes, RoleScope
    has_many :user_roles, UserRole

    timestamps()
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :label, :description, :system, :metadata])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9:_-]*$/)
    |> unique_constraint(:name)
  end

  defp normalize_name(name) when is_binary(name),
    do: name |> String.trim() |> String.downcase()

  defp normalize_name(name), do: name
end
