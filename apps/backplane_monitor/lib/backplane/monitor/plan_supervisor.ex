defmodule Backplane.Monitor.PlanSupervisor do
  @moduledoc """
  Dynamic supervisor and public process API for monitored plans.
  """

  use DynamicSupervisor

  import Ecto.Query

  alias Backplane.Monitor.Plan
  alias Backplane.Monitor.PlanServer
  alias Backplane.Repo

  @name __MODULE__
  @registry Backplane.Monitor.PlanRegistry
  @task_supervisor Backplane.Monitor.TaskSupervisor
  @refresh_timeout 120_000

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec sync_plans() :: :ok
  def sync_plans do
    if running?() do
      plans = list_db_plans()
      plan_ids = plans |> Enum.map(& &1.id) |> MapSet.new()

      Enum.each(plans, &ensure_plan/1)
      terminate_missing_processes(plan_ids)
    end

    :ok
  end

  @spec ensure_plan(Plan.t()) :: {:ok, pid()} | {:error, term()} | :ignore
  def ensure_plan(%Plan{} = plan) do
    cond do
      !running?() ->
        :ignore

      pid = PlanServer.whereis(plan.id) ->
        {:ok, pid}

      true ->
        DynamicSupervisor.start_child(@name, {PlanServer, start_opts(plan)})
    end
  end

  @spec update_plan(Plan.t()) :: :ok
  def update_plan(%Plan{} = plan) do
    case PlanServer.whereis(plan.id) do
      pid when is_pid(pid) ->
        PlanServer.update_plan(pid, plan)
        :ok

      nil ->
        ensure_plan(plan)
        :ok
    end
  end

  @spec stop_plan(Plan.t() | String.t()) :: :ok
  def stop_plan(%Plan{id: id}), do: stop_plan(id)

  def stop_plan(plan_id) when is_binary(plan_id) do
    with true <- running?(),
         pid when is_pid(pid) <- PlanServer.whereis(plan_id) do
      ref = Process.monitor(pid)
      DynamicSupervisor.terminate_child(@name, pid)
      await_down(ref)
    end

    :ok
  end

  @spec list_states(keyword()) :: [PlanServer.snapshot()]
  def list_states(opts \\ []) do
    sync_plans()

    active_only = Keyword.get(opts, :active_only, true)

    list_db_plans()
    |> Enum.flat_map(&state_for_plan/1)
    |> Enum.filter(fn %{plan: plan} -> !active_only or plan.active end)
    |> Enum.sort_by(& &1.plan.name)
  end

  @spec refresh_all(keyword()) :: [PlanServer.snapshot()]
  def refresh_all(opts \\ []) do
    opts
    |> list_states()
    |> refresh_states()
    |> Enum.sort_by(& &1.plan.name)
  end

  defp refresh_states([]), do: []

  defp refresh_states(states) do
    if Process.whereis(@task_supervisor) do
      @task_supervisor
      |> Task.Supervisor.async_stream_nolink(
        states,
        fn %{plan: plan} -> PlanServer.refresh(plan.id) end,
        max_concurrency: max(System.schedulers_online(), 1),
        timeout: @refresh_timeout,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, state} -> [state]
        {:exit, _reason} -> []
      end)
    else
      Enum.map(states, fn %{plan: plan} -> PlanServer.refresh(plan.id) end)
    end
  end

  defp state_for_plan(%Plan{} = plan) do
    case ensure_plan(plan) do
      {:ok, pid} -> [PlanServer.state(pid)]
      _ -> []
    end
  end

  defp terminate_missing_processes(plan_ids) do
    @name
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      case PlanServer.state(pid) do
        %{plan: %{id: id}} ->
          unless MapSet.member?(plan_ids, id) do
            DynamicSupervisor.terminate_child(@name, pid)
          end

        _ ->
          :ok
      end
    end)
  end

  defp list_db_plans do
    Plan |> order_by(:name) |> Repo.all()
  end

  defp start_opts(%Plan{} = plan) do
    case Application.get_env(:backplane_monitor, :req_test_owner) do
      owner when is_pid(owner) -> [plan: plan, req_test_owner: owner]
      _ -> [plan: plan]
    end
  end

  defp await_down(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp running? do
    Process.whereis(@name) != nil and Process.whereis(@registry) != nil
  end
end
