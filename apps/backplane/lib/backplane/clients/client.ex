defmodule Backplane.Clients.Client do
  @moduledoc """
  Ecto schema for MCP client identities with scoped tool access.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @scope_pattern ~r/^(\*|[\w-]+::\*|[\w-]+::[\w-]+)$/

  schema "clients" do
    field(:name, :string)
    field(:token_hash, :string)
    field(:scopes, {:array, :string})
    field(:active, :boolean, default: true)
    field(:last_seen_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  @required_fields ~w(name token_hash scopes)a
  @optional_fields ~w(active last_seen_at metadata)a

  @doc "Changeset for creating or updating a client."
  def changeset(client, attrs) do
    client
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name)
    |> validate_scopes()
  end

  defp validate_scopes(changeset) do
    case get_change(changeset, :scopes) do
      nil ->
        changeset

      [] ->
        add_error(changeset, :scopes, "must not be empty")

      scopes when is_list(scopes) ->
        invalid = Enum.reject(scopes, &Regex.match?(@scope_pattern, &1))

        if invalid == [] do
          changeset
        else
          add_error(changeset, :scopes, "invalid scope format: #{Enum.join(invalid, ", ")}")
        end
    end
  end
end
