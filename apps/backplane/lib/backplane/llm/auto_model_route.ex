defmodule Backplane.LLM.AutoModelRoute do
  @moduledoc """
  API-surface-specific route group for a Backplane auto model.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.AutoModel
  alias Backplane.LLM.AutoModelTarget
  alias Backplane.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "llm_auto_model_routes" do
    field(:api_surface, Ecto.Enum, values: [:openai, :anthropic])
    field(:strategy, Ecto.Enum, values: [:first_available], default: :first_available)
    field(:enabled, :boolean, default: true)

    belongs_to(:auto_model, AutoModel, type: :binary_id)
    has_many(:targets, AutoModelTarget, foreign_key: :auto_model_route_id)

    timestamps()
  end

  @required_fields ~w(auto_model_id api_surface strategy)a
  @optional_fields ~w(enabled)a

  @doc "Changeset for auto model routes."
  def changeset(route, attrs) do
    route
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:auto_model_id)
    |> unique_constraint([:auto_model_id, :api_surface])
  end

  @doc "Get a route by auto model name and API surface."
  @spec get_by_model_and_surface(String.t(), atom()) :: t() | nil
  def get_by_model_and_surface(name, api_surface) when api_surface in [:openai, :anthropic] do
    __MODULE__
    |> join(:inner, [route], auto_model in assoc(route, :auto_model))
    |> where([route, auto_model], auto_model.name == ^name and route.api_surface == ^api_surface)
    |> preload(:targets)
    |> Repo.one()
  end
end
