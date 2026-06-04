defmodule Backplane.Monitor.PlanServer do
  @moduledoc """
  Runtime process for one monitored subscription plan.

  The process keeps the latest usage snapshot in memory and refreshes it on
  demand or on a fixed interval while the plan is active.
  """

  use GenServer

  alias Backplane.Monitor.Plan
  alias Backplane.Monitor.Providers.{MiniMax, OpenAICodex, ZAI}
  alias Backplane.Monitor.UsageFetcher

  @registry Backplane.Monitor.PlanRegistry
  @refresh_interval :timer.minutes(5)
  @call_timeout 120_000

  defstruct [:plan, :usage, :fetched_at, :refresh_timer, :refresh_interval]

  @type usage_result :: {:ok, map()} | {:error, term()} | {:unsupported, String.t()}
  @type snapshot :: %{
          plan: Plan.t(),
          usage: usage_result() | nil,
          fetched_at: DateTime.t() | nil
        }

  @spec start_link(Plan.t() | keyword()) :: GenServer.on_start()
  def start_link(%Plan{} = plan), do: start_link(plan: plan)

  def start_link(opts) when is_list(opts) do
    plan = Keyword.fetch!(opts, :plan)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(plan.id))
  end

  @spec child_spec(Plan.t() | keyword()) :: Supervisor.child_spec()
  def child_spec(start_arg) do
    %{
      id: child_id(start_arg),
      start: {__MODULE__, :start_link, [start_arg]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec via_tuple(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via_tuple(plan_id), do: {:via, Registry, {@registry, plan_id}}

  @spec whereis(String.t()) :: pid() | nil
  def whereis(plan_id) do
    case Registry.lookup(@registry, plan_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  catch
    :exit, _reason -> nil
  end

  @spec state(pid() | String.t()) :: snapshot()
  def state(target), do: GenServer.call(call_target(target), :state, @call_timeout)

  @spec refresh(pid() | String.t()) :: snapshot()
  def refresh(target), do: GenServer.call(call_target(target), :refresh, @call_timeout)

  @spec refresh_async(pid() | String.t()) :: :ok
  def refresh_async(target), do: GenServer.cast(call_target(target), :refresh)

  @spec update_plan(pid() | String.t(), Plan.t()) :: snapshot()
  def update_plan(target, %Plan{} = plan) do
    GenServer.call(call_target(target), {:update_plan, plan}, @call_timeout)
  end

  @impl true
  def init(opts) do
    plan = Keyword.fetch!(opts, :plan)
    refresh_interval = Keyword.get(opts, :refresh_interval, @refresh_interval)

    allow_req_test(plan, Keyword.get(opts, :req_test_owner))

    state = %__MODULE__{
      plan: plan,
      refresh_interval: refresh_interval
    }

    {:ok, state, {:continue, :refresh_if_active}}
  end

  @impl true
  def handle_continue(:refresh_if_active, state) do
    {:noreply, refresh_if_active(state)}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, snapshot(state), state}
  end

  def handle_call(:refresh, _from, state) do
    state = refresh_if_active(state)
    {:reply, snapshot(state), state}
  end

  def handle_call({:update_plan, %Plan{} = plan}, _from, state) do
    state = %{cancel_refresh(state) | plan: plan}

    if plan.active do
      send(self(), :refresh)
    end

    {:reply, snapshot(state), state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, refresh_if_active(state)}
  end

  @impl true
  def handle_info(:refresh, state) do
    {:noreply, refresh_if_active(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp child_id(%Plan{id: id}), do: {__MODULE__, id}
  defp child_id(opts) when is_list(opts), do: child_id(Keyword.fetch!(opts, :plan))

  defp call_target(pid) when is_pid(pid), do: pid
  defp call_target(plan_id), do: via_tuple(plan_id)

  defp refresh_if_active(%{plan: %{active: false}} = state), do: cancel_refresh(state)

  defp refresh_if_active(state) do
    state = cancel_refresh(state)

    state
    |> Map.merge(%{
      usage: fetch_usage(state.plan),
      fetched_at: DateTime.utc_now()
    })
    |> schedule_refresh()
  end

  defp fetch_usage(%Plan{provider: provider} = plan) do
    if Plan.provider_supported?(provider) do
      case UsageFetcher.fetch_usage(plan) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    else
      {:unsupported, provider}
    end
  end

  defp allow_req_test(_plan, nil), do: :ok

  defp allow_req_test(%Plan{provider: provider}, owner) when is_pid(owner) do
    with {:module, Req.Test} <- Code.ensure_loaded(Req.Test),
         stub_name when not is_nil(stub_name) <- req_test_stub_name(provider) do
      Req.Test.allow(stub_name, owner, self())
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp req_test_stub_name("zai"), do: ZAI
  defp req_test_stub_name("minimax"), do: MiniMax
  defp req_test_stub_name("openai_codex"), do: OpenAICodex
  defp req_test_stub_name(_provider), do: nil

  defp schedule_refresh(%{refresh_interval: interval} = state)
       when is_integer(interval) and interval > 0 do
    %{state | refresh_timer: Process.send_after(self(), :refresh, interval)}
  end

  defp schedule_refresh(state), do: %{state | refresh_timer: nil}

  defp cancel_refresh(%{refresh_timer: nil} = state), do: state

  defp cancel_refresh(%{refresh_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | refresh_timer: nil}
  end

  defp snapshot(state) do
    %{
      plan: state.plan,
      usage: state.usage,
      fetched_at: state.fetched_at
    }
  end
end
