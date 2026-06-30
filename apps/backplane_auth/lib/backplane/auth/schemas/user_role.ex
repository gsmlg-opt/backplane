defmodule Backplane.Auth.Schemas.UserRole do
  @moduledoc "Role assignment for a Backplane Auth user."

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Auth.Schemas.{Role, User}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "auth_user_roles" do
    belongs_to :user, User
    belongs_to :role, Role

    timestamps()
  end

  def changeset(user_role, attrs) do
    user_role
    |> cast(attrs, [:user_id, :role_id])
    |> validate_required([:user_id, :role_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:role_id)
    |> unique_constraint([:user_id, :role_id])
  end
end
