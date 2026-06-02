defmodule Backplane.Embedding.Provider do
  @moduledoc """
  Provider configuration for embedding-only upstreams.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Embedding.Model

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @name_pattern ~r/^[a-z0-9][a-z0-9-]*$/
  @allowed_schemes ~w(http https)

  schema "embedding_providers" do
    field(:name, :string)
    field(:credential, :string)
    field(:base_url, :string)
    field(:default_headers, :map, default: %{})
    field(:enabled, :boolean, default: true)
    field(:deleted_at, :utc_datetime_usec)

    has_many(:models, Model, foreign_key: :provider_id)

    timestamps()
  end

  @required_fields ~w(name credential base_url)a
  @optional_fields ~w(default_headers enabled deleted_at)a

  @doc "Changeset for creating or updating an embedding provider."
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> update_change(:base_url, &trim_trailing_slash/1)
    |> validate_required(@required_fields)
    |> validate_format(:name, @name_pattern,
      message:
        "must start with a lowercase letter or digit and contain only lowercase letters, digits, and hyphens"
    )
    |> validate_base_url()
    |> validate_default_headers()
    |> validate_credential_exists()
    |> unique_constraint(:name, name: :embedding_providers_name_index)
  end

  defp trim_trailing_slash(url) when is_binary(url), do: String.trim_trailing(url, "/")
  defp trim_trailing_slash(url), do: url

  defp validate_base_url(changeset) do
    validate_change(changeset, :base_url, fn :base_url, url ->
      uri = URI.parse(url)

      if uri.scheme in @allowed_schemes and is_binary(uri.host) and uri.host != "" do
        []
      else
        [base_url: "must be an http or https URL"]
      end
    end)
  end

  defp validate_default_headers(changeset) do
    validate_change(changeset, :default_headers, fn
      :default_headers, headers when is_map(headers) -> []
      :default_headers, _headers -> [default_headers: "must be a map"]
    end)
  end

  defp validate_credential_exists(changeset) do
    case get_field(changeset, :credential) do
      nil ->
        changeset

      "" ->
        changeset

      name ->
        if Backplane.Settings.Credentials.exists?(name),
          do: changeset,
          else: add_error(changeset, :credential, "credential '#{name}' not found")
    end
  end
end
