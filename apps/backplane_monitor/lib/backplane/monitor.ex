defmodule Backplane.Monitor do
  @moduledoc """
  Context module for managing subscription plan monitoring definitions.

  Plans define which provider subscriptions to monitor and which credential
  to use for API access.
  """

  import Ecto.Query

  alias Backplane.Monitor.Plan
  alias Backplane.Monitor.PlanSupervisor
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
    |> after_plan_saved()
  end

  @doc "Update an existing plan."
  @spec update_plan(Plan.t(), map()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def update_plan(%Plan{} = plan, attrs) do
    plan
    |> Plan.changeset(attrs)
    |> Repo.update()
    |> after_plan_saved()
  end

  @doc "Delete a plan."
  @spec delete_plan(Plan.t()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def delete_plan(%Plan{} = plan) do
    case Repo.delete(plan) do
      {:ok, deleted_plan} = result ->
        PlanSupervisor.stop_plan(deleted_plan)
        result

      {:error, _changeset} = result ->
        result
    end
  end

  @doc "List latest usage snapshots from active plan processes."
  @spec list_plan_usage_states(keyword()) :: [Backplane.Monitor.PlanServer.snapshot()]
  def list_plan_usage_states(opts \\ []) do
    PlanSupervisor.list_states(opts)
  end

  @doc "Ask plan processes to refresh usage and return their latest snapshots."
  @spec refresh_plan_usages(keyword()) :: [Backplane.Monitor.PlanServer.snapshot()]
  def refresh_plan_usages(opts \\ []) do
    PlanSupervisor.refresh_all(opts)
  end

  defp after_plan_saved({:ok, %Plan{} = plan} = result) do
    PlanSupervisor.update_plan(plan)
    result
  end

  defp after_plan_saved(result), do: result
end
