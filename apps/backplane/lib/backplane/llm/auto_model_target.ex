defmodule Backplane.LLM.AutoModelTarget do
  @moduledoc """
  Ordered provider model target for an auto model route.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.LLM.AutoModelRoute
  alias Backplane.LLM.ProviderModelSurface
  alias Backplane.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "llm_auto_model_targets" do
    field(:priority, :integer, default: 0)
    field(:enabled, :boolean, default: true)

    belongs_to(:auto_model_route, AutoModelRoute, type: :binary_id)
    belongs_to(:provider_model_surface, ProviderModelSurface, type: :binary_id)

    timestamps()
  end

  @required_fields ~w(auto_model_route_id provider_model_surface_id priority)a
  @optional_fields ~w(enabled)a

  @doc "Changeset for auto model targets."
  def changeset(target, attrs) do
    target
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_same_api_surface()
    |> foreign_key_constraint(:auto_model_route_id)
    |> foreign_key_constraint(:provider_model_surface_id)
    |> unique_constraint([:auto_model_route_id, :provider_model_surface_id])
  end

  @doc "Create an auto model target."
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  defp validate_same_api_surface(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_same_api_surface(changeset) do
    route_id = get_field(changeset, :auto_model_route_id)
    surface_id = get_field(changeset, :provider_model_surface_id)

    with true <- is_binary(route_id),
         true <- is_binary(surface_id),
         %AutoModelRoute{} = route <- Repo.get(AutoModelRoute, route_id),
         %ProviderModelSurface{} = surface <-
           ProviderModelSurface |> Repo.get(surface_id) |> Repo.preload(:provider_api),
         true <- route.api_surface == surface.provider_api.api_surface do
      changeset
    else
      false ->
        add_error(
          changeset,
          :provider_model_surface_id,
          "must use the same API surface as the route"
        )

      nil ->
        changeset

      _ ->
        changeset
    end
  end
end
