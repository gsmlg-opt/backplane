defmodule Backplane.Monitor do
  @moduledoc """
  Context module for managing subscription plan monitoring definitions.

  Plans define which provider subscriptions to monitor and which credential
  to use for API access.
  """

  import Ecto.Query

  alias Backplane.Monitor.Plan
  alias Backplane.Repo

  @doc "List all plans, ordered by name."
  @spec list_plans() :: [Plan.t()]
  def list_plans do
    Plan |> order_by(:name) |> Repo.all()
  end

  @doc "List only active plans."
  @spec list_active_plans() :: [Plan.t()]
  def list_active_plans do
    Plan |> where(active: true) |> order_by(:name) |> Repo.all()
  end

  @doc "Get a plan by ID."
  @spec get_plan(String.t()) :: Plan.t() | nil
  def get_plan(id), do: Repo.get(Plan, id)

  @doc "Get a plan by ID, raises if not found."
  @spec get_plan!(String.t()) :: Plan.t()
  def get_plan!(id), do: Repo.get!(Plan, id)

  @doc "Create a new plan."
  @spec create_plan(map()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def create_plan(attrs) when is_map(attrs) do
    %Plan{}
    |> Plan.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing plan."
  @spec update_plan(Plan.t(), map()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def update_plan(%Plan{} = plan, attrs) do
    plan
    |> Plan.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a plan."
  @spec delete_plan(Plan.t()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def delete_plan(%Plan{} = plan) do
    Repo.delete(plan)
  end
end
