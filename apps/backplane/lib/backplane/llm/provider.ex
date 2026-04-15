defmodule Backplane.LLM.Provider do
  @moduledoc """
  Ecto schema and context for LLM providers.

  Each provider represents a configured connection to an LLM API (Anthropic,
  OpenAI, etc.). Credentials are stored in the centralized credential store
  and referenced by name.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.ModelAlias
  alias Backplane.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @name_pattern ~r/^[a-z0-9][a-z0-9-]*$/
  @localhost_pattern ~r/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?(\/.*)?$/

  schema "llm_providers" do
    field(:name, :string)
    field(:api_type, Ecto.Enum, values: [:anthropic, :openai])
    field(:api_url, :string)
    field(:credential, :string)
    field(:models, {:array, :string})
    field(:default_headers, :map, default: %{})
    field(:rpm_limit, :integer)
    field(:enabled, :boolean, default: true)
    field(:deleted_at, :utc_datetime_usec)

    has_many(:aliases, ModelAlias, foreign_key: :provider_id)

    timestamps()
  end

  @required_fields ~w(name api_type api_url models credential)a
  @optional_fields ~w(default_headers rpm_limit enabled)a

  # ── Changesets ───────────────────────────────────────────────────────────────

  @doc "Changeset for creating a new provider."
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:name, @name_pattern,
      message: "must start with a lowercase letter or digit and contain only lowercase letters, digits, and hyphens"
    )
    |> validate_api_url()
    |> validate_models_not_empty()
    |> validate_credential_exists()
    |> unique_constraint(:name, name: :llm_providers_name_index)
  end

  @doc "Changeset for updating an existing provider."
  def update_changeset(provider, attrs) do
    provider
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_format(:name, @name_pattern,
      message: "must start with a lowercase letter or digit and contain only lowercase letters, digits, and hyphens"
    )
    |> validate_api_url()
    |> validate_models_not_empty()
    |> validate_credential_exists()
    |> unique_constraint(:name, name: :llm_providers_name_index)
  end

  defp validate_api_url(changeset) do
    case get_change(changeset, :api_url) || get_field(changeset, :api_url) do
      nil ->
        changeset

      url ->
        cond do
          Regex.match?(@localhost_pattern, url) ->
            changeset

          String.starts_with?(url, "https://") ->
            changeset

          String.starts_with?(url, "http://") ->
            add_error(changeset, :api_url, "must use https:// (http:// is only allowed for localhost/127.0.0.1)")

          true ->
            add_error(changeset, :api_url, "must start with https://")
        end
    end
  end

  defp validate_models_not_empty(changeset) do
    case get_change(changeset, :models) do
      nil ->
        changeset

      [] ->
        add_error(changeset, :models, "must have at least one model")

      _models ->
        changeset
    end
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

  Runs in a transaction:
  1. Hard-deletes all ModelAlias records for this provider
  2. Sets deleted_at and enabled=false on the provider
  3. Broadcasts on success
  """
  @spec soft_delete(t()) :: {:ok, t()} | {:error, any()}
  def soft_delete(%__MODULE__{} = provider) do
    result =
      Repo.transaction(fn ->
        # Hard-delete aliases
        from(a in ModelAlias, where: a.provider_id == ^provider.id)
        |> Repo.delete_all()

        # Soft-delete provider
        now = DateTime.utc_now()

        provider
        |> cast(%{deleted_at: now, enabled: false}, [:deleted_at, :enabled])
        |> Repo.update!()
      end)

    if match?({:ok, _}, result) do
      broadcast()
    end

    result
  end

  @doc "List all active (non-deleted) providers ordered by name, with preloaded aliases."
  @spec list() :: [t()]
  def list do
    __MODULE__
    |> where([p], is_nil(p.deleted_at))
    |> order_by(:name)
    |> preload(:aliases)
    |> Repo.all()
  end

  @doc "Get a single active provider by id with preloaded aliases."
  @spec get(binary()) :: t() | nil
  def get(id) do
    __MODULE__
    |> where([p], is_nil(p.deleted_at))
    |> preload(:aliases)
    |> Repo.get(id)
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp broadcast do
    Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
  end
end
