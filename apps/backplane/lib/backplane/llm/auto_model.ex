defmodule Backplane.LLM.AutoModel do
  @moduledoc """
  Backplane-owned public model names such as fast, smart, and expert.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.AutoModelRoute
  alias Backplane.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @allowed_names ~w(fast smart expert)

  schema "llm_auto_models" do
    field(:name, :string)
    field(:description, :string)
    field(:enabled, :boolean, default: true)

    has_many(:routes, AutoModelRoute, foreign_key: :auto_model_id)

    timestamps()
  end

  @required_fields ~w(name)a
  @optional_fields ~w(description enabled)a

  @doc "Changeset for auto models."
  def changeset(auto_model, attrs) do
    auto_model
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:name, @allowed_names)
    |> unique_constraint(:name)
  end

  @doc "List auto models with routes and targets."
  @spec list() :: [t()]
  def list do
    __MODULE__
    |> order_by([model], model.name)
    |> preload(routes: [:targets])
    |> Repo.all()
  end
end
