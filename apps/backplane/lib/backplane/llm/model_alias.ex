defmodule Backplane.LLM.ModelAlias do
  @moduledoc """
  Ecto schema and context for LLM model aliases.

  An alias is a short name (e.g. "fast") that maps to a specific model on a
  specific provider. Clients can route requests through aliases without knowing
  provider-specific model IDs.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.Provider
  alias Backplane.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "llm_model_aliases" do
    field(:alias, :string)
    field(:model, :string)
    belongs_to(:provider, Provider, type: :binary_id)

    timestamps()
  end

  @required_fields ~w(alias model provider_id)a

  # ── Changesets ───────────────────────────────────────────────────────────────

  @doc "Changeset for creating a model alias."
  def changeset(model_alias, attrs) do
    model_alias
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_format(:alias, ~r/^[^\/]+$/, message: "must not contain /")
    |> unique_constraint(:alias)
    |> validate_model_in_provider()
    |> validate_provider_not_deleted()
  end

  defp validate_model_in_provider(%Ecto.Changeset{valid?: false} = cs), do: cs

  defp validate_model_in_provider(changeset) do
    provider_id = get_field(changeset, :provider_id)
    model = get_field(changeset, :model)

    if provider_id && model do
      changeset
      |> check_model_in_provider(Repo.get(Provider, provider_id), model)
    else
      changeset
    end
  end

  defp check_model_in_provider(changeset, nil, _model) do
    add_error(changeset, :provider_id, "does not exist")
  end

  defp check_model_in_provider(changeset, provider, model) do
    if model in (provider.models || []) do
      changeset
    else
      add_error(changeset, :model, "must be one of the provider's models")
    end
  end

  defp validate_provider_not_deleted(%Ecto.Changeset{valid?: false} = cs), do: cs

  defp validate_provider_not_deleted(changeset) do
    provider_id = get_field(changeset, :provider_id)

    if provider_id do
      case Repo.get(Provider, provider_id) do
        %Provider{deleted_at: nil} -> changeset
        %Provider{} -> add_error(changeset, :provider_id, "provider has been deleted")
        nil -> changeset
      end
    else
      changeset
    end
  end

  # ── Context ──────────────────────────────────────────────────────────────────

  @doc "Create a model alias and broadcast the change."
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    result =
      %__MODULE__{}
      |> changeset(attrs)
      |> Repo.insert()

    if match?({:ok, _}, result) do
      Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
    end

    result
  end

  @doc "Update a model alias and broadcast the change."
  @spec update(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(%__MODULE__{} = model_alias, attrs) do
    result =
      model_alias
      |> changeset(attrs)
      |> Repo.update()

    if match?({:ok, _}, result) do
      Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
    end

    result
  end

  @doc "Delete a model alias and broadcast the change."
  @spec delete(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def delete(%__MODULE__{} = model_alias) do
    result = Repo.delete(model_alias)

    if match?({:ok, _}, result) do
      Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
    end

    result
  end

  @doc "List all model aliases ordered by alias, with preloaded provider."
  @spec list() :: [t()]
  def list do
    __MODULE__
    |> order_by(:alias)
    |> preload(:provider)
    |> Repo.all()
  end

  @doc "Get a single model alias by id, with preloaded provider."
  @spec get(binary()) :: t() | nil
  def get(id) do
    __MODULE__
    |> preload(:provider)
    |> Repo.get(id)
  end

  @doc """
  Resolve an alias name to a provider + model tuple.

  The provider must be enabled and not deleted. Returns
  `{:ok, provider, model}` or `{:error, :not_found}`.
  """
  @spec resolve(String.t()) :: {:ok, Provider.t(), String.t()} | {:error, :not_found}
  def resolve(alias_name) when is_binary(alias_name) do
    result =
      from(a in __MODULE__,
        join: p in Provider,
        on: a.provider_id == p.id and p.enabled == true and is_nil(p.deleted_at),
        where: a.alias == ^alias_name,
        select: {p, a.model}
      )
      |> Repo.one()

    case result do
      {provider, model} -> {:ok, provider, model}
      nil -> {:error, :not_found}
    end
  end
end
