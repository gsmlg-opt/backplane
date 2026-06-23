defmodule Backplane.LLM.Provider do
  @moduledoc """
  Ecto schema and context for LLM providers.

  A provider represents one upstream LLM service. API protocol surfaces such as
  OpenAI-compatible and Anthropic Messages are modeled separately by
  `Backplane.LLM.ProviderApi`.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.ProviderApi
  alias Backplane.LLM.ProviderModel
  alias Backplane.LLM.ProviderPreset
  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @name_pattern ~r/^[a-z0-9][a-z0-9-]*$/

  schema "llm_providers" do
    field(:preset_key, :string)
    field(:name, :string)
    field(:credential, :string)
    field(:default_headers, :map, default: %{})
    field(:rpm_limit, :integer)
    field(:enabled, :boolean, default: true)
    field(:deleted_at, :utc_datetime_usec)
    field(:api_type, Ecto.Enum, values: [:anthropic, :openai], virtual: true)

    has_many(:apis, ProviderApi, foreign_key: :provider_id)
    has_many(:models, ProviderModel, foreign_key: :provider_id)

    timestamps()
  end

  @required_fields ~w(name credential)a
  @optional_fields ~w(preset_key default_headers rpm_limit enabled api_type)a

  # ── Changesets ───────────────────────────────────────────────────────────────

  @doc "Changeset for creating a new provider."
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:name, @name_pattern,
      message:
        "must start with a lowercase letter or digit and contain only lowercase letters, digits, and hyphens"
    )
    |> validate_number(:rpm_limit, greater_than: 0)
    |> validate_default_headers()
    |> validate_credential_exists()
    |> validate_preset_credential_auth_type()
    |> unique_constraint(:name, name: :llm_providers_name_index)
  end

  @doc "Changeset for updating an existing provider."
  def update_changeset(provider, attrs) do
    provider
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_format(:name, @name_pattern,
      message:
        "must start with a lowercase letter or digit and contain only lowercase letters, digits, and hyphens"
    )
    |> validate_number(:rpm_limit, greater_than: 0)
    |> validate_default_headers()
    |> validate_credential_exists()
    |> validate_preset_credential_auth_type()
    |> unique_constraint(:name, name: :llm_providers_name_index)
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

  defp validate_preset_credential_auth_type(changeset) do
    preset = preset_for_auth_type(get_field(changeset, :preset_key))
    credential = get_field(changeset, :credential)

    cond do
      is_nil(preset) ->
        changeset

      credential in [nil, ""] ->
        changeset

      Keyword.has_key?(changeset.errors, :credential) ->
        changeset

      credential_auth_type(credential) == preset.credential_auth_type ->
        changeset

      true ->
        add_error(changeset, :credential, "must use #{preset.credential_auth_type} auth type")
    end
  end

  defp preset_for_auth_type(preset_key) when is_binary(preset_key) do
    case ProviderPreset.get(preset_key) do
      %{credential_auth_type: auth_type} = preset when is_binary(auth_type) -> preset
      _ -> nil
    end
  end

  defp preset_for_auth_type(_preset_key), do: nil

  defp credential_auth_type(name) do
    Credentials.list()
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> nil
      credential -> credential_metadata_auth_type(credential.metadata)
    end
  end

  defp credential_metadata_auth_type(metadata) when is_map(metadata) do
    Map.get(metadata, "auth_type") || Map.get(metadata, :auth_type) || "api_key"
  end

  defp credential_metadata_auth_type(_metadata), do: "api_key"

  # ── Context ──────────────────────────────────────────────────────────────────

  @doc "Create a provider. Broadcasts on success."
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    result =
      %__MODULE__{}
      |> changeset(attrs)
      |> Repo.insert()

    if match?({:ok, _}, result) do
      broadcast()
    end

    result
  end

  @doc "Update a provider. Broadcasts on success."
  @spec update(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(%__MODULE__{} = provider, attrs) do
    result =
      provider
      |> update_changeset(attrs)
      |> Repo.update()

    if match?({:ok, _}, result) do
      broadcast()
    end

    result
  end

  @doc """
  Soft-delete a provider.

  Sets `deleted_at` and `enabled=false`. Child rows stay in place for audit and
  admin history, but resolvers must exclude deleted providers.
  """
  @spec soft_delete(t()) :: {:ok, t()} | {:error, any()}
  def soft_delete(%__MODULE__{} = provider) do
    result =
      provider
      |> cast(%{deleted_at: DateTime.utc_now(), enabled: false}, [:deleted_at, :enabled])
      |> Repo.update()

    if match?({:ok, _}, result) do
      broadcast()
    end

    result
  end

  @doc "List all active providers ordered by name."
  @spec list() :: [t()]
  def list do
    __MODULE__
    |> where([p], is_nil(p.deleted_at))
    |> order_by(:name)
    |> preload([:apis, models: [:surfaces]])
    |> Repo.all()
  end

  @doc "Get a single active provider by id."
  @spec get(binary()) :: t() | nil
  def get(id) do
    __MODULE__
    |> where([p], is_nil(p.deleted_at))
    |> preload([:apis, models: [:surfaces]])
    |> Repo.get(id)
  end

  @doc "Normalize and validate a provider API URL."
  @spec validate_api_url(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_api_url(changeset, field) do
    case get_change(changeset, field) || get_field(changeset, field) do
      nil ->
        changeset

      url ->
        cond do
          String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
            changeset

          true ->
            add_error(changeset, field, "must start with http:// or https://")
        end
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp broadcast do
    Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
  end
end
