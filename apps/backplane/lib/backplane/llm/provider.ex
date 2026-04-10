defmodule Backplane.LLM.Provider do
  @moduledoc """
  Ecto schema and context for LLM providers.

  Each provider represents a configured connection to an LLM API (Anthropic,
  OpenAI, etc.). API keys are encrypted at rest using AES-256-GCM.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.Encryption
  alias Backplane.LLM.ModelAlias
  alias Backplane.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @derive {Inspect, except: [:api_key_encrypted, :api_key]}
  @name_pattern ~r/^[a-z0-9][a-z0-9-]*$/
  @localhost_pattern ~r/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?(\/.*)?$/

  schema "llm_providers" do
    field(:name, :string)
    field(:api_type, Ecto.Enum, values: [:anthropic, :openai])
    field(:api_url, :string)
    field(:api_key_encrypted, :binary)
    field(:api_key, :string, virtual: true)
    field(:credential, :string)
    field(:models, {:array, :string})
    field(:default_headers, :map, default: %{})
    field(:rpm_limit, :integer)
    field(:enabled, :boolean, default: true)
    field(:deleted_at, :utc_datetime_usec)

    has_many(:aliases, ModelAlias, foreign_key: :provider_id)

    timestamps()
  end

  @required_fields ~w(name api_type api_url models)a
  @optional_fields ~w(default_headers rpm_limit enabled credential)a
  @update_extra_fields ~w(api_key)a

  # ── Changesets ───────────────────────────────────────────────────────────────

  @doc "Changeset for creating a new provider."
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @required_fields ++ @optional_fields ++ [:api_key])
    |> validate_required(@required_fields)
    |> validate_format(:name, @name_pattern,
      message: "must start with a lowercase letter or digit and contain only lowercase letters, digits, and hyphens"
    )
    |> validate_api_url()
    |> validate_models_not_empty()
    |> validate_api_key_on_insert()
    |> maybe_encrypt_api_key()
    |> unique_constraint(:name, name: :llm_providers_name_active_index)
  end

  @doc "Changeset for updating an existing provider."
  def update_changeset(provider, attrs) do
    provider
    |> cast(attrs, @required_fields ++ @optional_fields ++ @update_extra_fields)
    |> validate_format(:name, @name_pattern,
      message: "must start with a lowercase letter or digit and contain only lowercase letters, digits, and hyphens"
    )
    |> validate_api_url()
    |> validate_models_not_empty()
    |> maybe_encrypt_api_key()
    |> unique_constraint(:name, name: :llm_providers_name_active_index)
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

  defp validate_api_key_on_insert(%Ecto.Changeset{data: %{api_key_encrypted: nil}} = changeset) do
    has_api_key =
      case get_field(changeset, :api_key) do
        nil -> false
        "" -> false
        _ -> true
      end

    has_credential =
      case get_field(changeset, :credential) do
        nil -> false
        "" -> false
        _ -> true
      end

    if has_api_key or has_credential do
      changeset
    else
      add_error(changeset, :api_key, "is required when creating a new provider (or set credential)")
    end
  end

  defp validate_api_key_on_insert(changeset), do: changeset

  defp maybe_encrypt_api_key(changeset) do
    case get_change(changeset, :api_key) do
      nil ->
        changeset

      "" ->
        changeset

      api_key when is_binary(api_key) ->
        key = Encryption.get_key()
        encrypted = Encryption.encrypt(api_key, key)

        changeset
        |> put_change(:api_key_encrypted, encrypted)
        |> delete_change(:api_key)
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

  @doc "Decrypt the provider's API key. Returns {:ok, key} or :error."
  @spec decrypt_api_key(t()) :: {:ok, String.t()} | :error
  def decrypt_api_key(%__MODULE__{api_key_encrypted: encrypted}) when is_binary(encrypted) do
    key = Encryption.get_key()
    Encryption.decrypt(encrypted, key)
  end

  def decrypt_api_key(_), do: :error

  @doc "Return a hint of the API key (last 4 chars). Example: \"...a1b2\"."
  @spec api_key_hint(t()) :: String.t() | nil
  def api_key_hint(%__MODULE__{api_key_encrypted: nil}), do: nil

  def api_key_hint(%__MODULE__{} = provider) do
    case decrypt_api_key(provider) do
      {:ok, key} when byte_size(key) >= 4 ->
        "..." <> String.slice(key, -4, 4)

      {:ok, key} ->
        "..." <> key

      :error ->
        nil
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp broadcast do
    Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
  end
end
