defmodule Backplane.Auth.Schemas.OAuthTokenResource do
  @moduledoc """
  One-to-one protected-resource binding for a Boruta OAuth token row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "oauth_token_resources" do
    belongs_to :oauth_token, Boruta.Ecto.Token
    field :resource, :string

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:oauth_token_id, :resource])
    |> validate_required([:oauth_token_id, :resource])
    |> validate_inclusion(:resource, ["mcp", "v1"])
    |> foreign_key_constraint(:oauth_token_id)
    |> unique_constraint(:oauth_token_id,
      name: :oauth_token_resources_oauth_token_id_index
    )
    |> check_constraint(:resource, name: :oauth_token_resources_resource_check)
  end
end
