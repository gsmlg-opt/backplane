defmodule Backplane.Monitor.ApiUsageServer do
  @moduledoc "Caches API-account usage while supervised tasks perform bounded provider requests."

  use GenServer

  alias Backplane.Monitor.{ApiAccounts, ApiUsageFetcher}
  alias Backplane.Monitor.Providers.{DeepSeek, Exa, Firecrawl, OpenRouter, Tavily}

  @refresh_interval :timer.minutes(5)
  @request_timeout :timer.seconds(45)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def sync(accounts), do: sync(__MODULE__, accounts)
  def sync(server, accounts), do: GenServer.call(server, {:sync, accounts})
  def load_states(server \\ __MODULE__), do: GenServer.call(server, :load_states, 10_000)
  def definition_changed(id), do: definition_changed(__MODULE__, id)
  def definition_changed(server, id), do: GenServer.cast(server, {:definition_changed, id})
  def states(server \\ __MODULE__), do: GenServer.call(server, :states)
  def refresh(id), do: refresh(__MODULE__, id)
  def refresh(server, id), do: GenServer.call(server, {:refresh, id})
  def refresh_all(server \\ __MODULE__), do: GenServer.call(server, :refresh_all)

  def reload_fetching_policy(server \\ __MODULE__),
    do: GenServer.call(server, :reload_fetching_policy)

  @impl true
  def init(opts) do
    Backplane.Settings.subscribe()
    enabled_reader = Keyword.get(opts, :enabled_reader, &ApiAccounts.fetching_enabled?/0)

    state = %{
      snapshots: %{},
      tasks: %{},
      invalidated: MapSet.new(),
      generation: 0,
      definition: nil,
      fetching_enabled: enabled_reader.(),
      enabled_reader: enabled_reader,
      account_loader: Keyword.get(opts, :account_loader, &ApiAccounts.list_accounts/0),
      definition_timeout: Keyword.get(opts, :definition_timeout, 5_000),
      waiter_timeout: Keyword.get(opts, :waiter_timeout, 8_000),
      fetcher: Keyword.get(opts, :fetcher, &ApiUsageFetcher.fetch_usage/1),
      task_supervisor: Keyword.get(opts, :task_supervisor, Backplane.Monitor.TaskSupervisor),
      refresh_interval: Keyword.get(opts, :refresh_interval, @refresh_interval),
      request_timeout: Keyword.get(opts, :request_timeout, @request_timeout)
    }

    {:ok, schedule_poll(state)}
  end

  @impl true
  def handle_call({:sync, accounts}, _from, state) do
    waiters = if state.definition, do: state.definition.waiters, else: []
    state = cancel_definition_load(state)
    state = reconcile(%{state | generation: state.generation + 1}, accounts)
    state = reply_waiters(state, waiters)
    {:reply, snapshots(state), state}
  end

  def handle_call(:states, _from, state), do: {:reply, snapshots(state), state}

  def handle_call(:load_states, from, state) do
    token = make_ref()
    timer = Process.send_after(self(), {:waiter_timeout, token}, state.waiter_timeout)
    {:noreply, load_definitions(state, [%{from: from, token: token, timer: timer}], false)}
  end

  def handle_call({:refresh, id}, _from, state) do
    {:reply, :ok, start_refresh(state, id)}
  end

  def handle_call(:refresh_all, _from, state) do
    {:reply, :ok, refresh_snapshots(state)}
  end

  def handle_call(:reload_fetching_policy, _from, state) do
    {:reply, :ok, apply_fetching_policy(state)}
  end

  @impl true
  def handle_cast({:definition_changed, id}, state) do
    state =
      Enum.reduce(state.tasks, state, fn {reference, task}, current ->
        if task.id == id, do: cancel_task(current, reference, task), else: current
      end)

    state =
      case Map.get(state.snapshots, id) do
        nil -> state
        snapshot -> put_snapshot(state, id, %{snapshot | refreshing: false})
      end

    state = %{
      state
      | generation: state.generation + 1,
        invalidated: MapSet.put(state.invalidated, id)
    }

    {:noreply, load_definitions(state, [], false)}
  end

  @impl true
  def handle_info(:poll, state) do
    {:noreply, state |> load_definitions([], true) |> schedule_poll()}
  end

  def handle_info({:setting_changed, "monitor.api_usage.enabled", _value}, state) do
    {:noreply, apply_fetching_policy(state)}
  end

  def handle_info({:waiter_timeout, token}, %{definition: definition} = state)
      when not is_nil(definition) do
    {expired, pending} = Enum.split_with(definition.waiters, &(&1.token == token))
    state = reply_waiters(state, expired)
    {:noreply, %{state | definition: %{definition | waiters: pending}}}
  end

  def handle_info(
        {reference, result},
        %{definition: %{task: %{ref: reference}} = definition} = state
      ) do
    Process.demonitor(reference, [:flush])
    Process.cancel_timer(definition.timer)
    {:noreply, finish_definitions(%{state | definition: nil}, definition, result)}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %{definition: %{task: %{ref: reference}} = definition} = state
      ) do
    Process.cancel_timer(definition.timer)
    {:noreply, finish_definitions(%{state | definition: nil}, definition, {:error, :load_failed})}
  end

  def handle_info(
        {:definition_timeout, reference},
        %{definition: %{task: %{ref: reference}} = definition} = state
      ) do
    Task.shutdown(definition.task, :brutal_kill)
    {:noreply, finish_definitions(%{state | definition: nil}, definition, {:error, :load_failed})}
  end

  def handle_info({reference, result}, state) when is_reference(reference) do
    case Map.pop(state.tasks, reference) do
      {nil, _tasks} ->
        {:noreply, state}

      {task, tasks} ->
        Process.demonitor(reference, [:flush])
        Process.cancel_timer(task.timer)
        state = %{state | tasks: tasks}
        {:noreply, finish_refresh(state, task.id, result)}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    case Map.pop(state.tasks, reference) do
      {nil, _tasks} ->
        {:noreply, state}

      {task, tasks} ->
        Process.cancel_timer(task.timer)
        {:noreply, finish_refresh(%{state | tasks: tasks}, task.id, {:error, :refresh_failed})}
    end
  end

  def handle_info({:request_timeout, reference}, state) do
    case Map.get(state.tasks, reference) do
      nil ->
        {:noreply, state}

      task ->
        state = cancel_task(state, reference, task)
        {:noreply, finish_refresh(state, task.id, {:error, :request_timeout})}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn {_reference, task} ->
      Process.cancel_timer(task.timer)
      Task.shutdown(task.task, :brutal_kill)
    end)

    if state.definition do
      Process.cancel_timer(state.definition.timer)
      Enum.each(state.definition.waiters, &Process.cancel_timer(&1.timer))
      Task.shutdown(state.definition.task, :brutal_kill)
    end
  end

  defp load_definitions(%{definition: nil} = state, waiters, refresh) do
    loader = state.account_loader
    task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> safely_load(loader) end)
    timer = Process.send_after(self(), {:definition_timeout, task.ref}, state.definition_timeout)

    definition = %{
      task: task,
      timer: timer,
      generation: state.generation,
      waiters: waiters,
      refresh: refresh
    }

    %{state | definition: definition}
  end

  defp load_definitions(state, waiters, refresh) do
    definition = %{
      state.definition
      | waiters: waiters ++ state.definition.waiters,
        refresh: refresh or state.definition.refresh
    }

    %{state | definition: definition}
  end

  defp safely_load(loader) do
    {:ok, loader.()}
  rescue
    _exception -> {:error, :load_failed}
  catch
    _kind, _reason -> {:error, :load_failed}
  end

  defp cancel_definition_load(%{definition: nil} = state), do: state

  defp cancel_definition_load(state) do
    Process.cancel_timer(state.definition.timer)
    Task.shutdown(state.definition.task, :brutal_kill)
    %{state | definition: nil}
  end

  defp finish_definitions(state, definition, {:ok, accounts}) do
    if definition.generation == state.generation do
      state = reconcile(state, accounts)
      state = if definition.refresh, do: refresh_snapshots(state), else: state
      reply_waiters(state, definition.waiters)
    else
      load_definitions(state, definition.waiters, definition.refresh)
    end
  end

  defp finish_definitions(state, definition, {:error, :load_failed}) do
    reply_waiters(state, definition.waiters)
  end

  defp reply_waiters(state, waiters) do
    Enum.each(waiters, fn waiter ->
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, snapshots(state))
    end)

    state
  end

  defp reconcile(state, accounts) do
    account_map = Map.new(accounts, &{&1.id, &1})
    invalidated = state.invalidated
    state = %{state | invalidated: MapSet.new()}

    state =
      Enum.reduce(state.tasks, state, fn {reference, task}, current ->
        if Map.get(account_map, task.id) != current.snapshots[task.id].account do
          cancel_task(current, reference, task)
        else
          current
        end
      end)

    Enum.reduce(
      accounts,
      %{state | snapshots: Map.take(state.snapshots, Map.keys(account_map))},
      fn account, current ->
        case Map.get(current.snapshots, account.id) do
          %{account: ^account} ->
            if MapSet.member?(invalidated, account.id),
              do: start_refresh(current, account.id),
              else: current

          previous ->
            snapshot =
              if previous && same_credentials?(previous.account, account) do
                %{previous | account: account, refreshing: false}
              else
                empty_snapshot(account)
              end

            current
            |> put_snapshot(account.id, snapshot)
            |> start_refresh(account.id)
        end
      end
    )
  end

  defp same_credentials?(previous, current) do
    {previous.provider, previous.credential_name, previous.management_credential_name} ==
      {current.provider, current.credential_name, current.management_credential_name}
  end

  defp refresh_snapshots(state) do
    Enum.reduce(Map.keys(state.snapshots), state, &start_refresh(&2, &1))
  end

  defp start_refresh(state, id) do
    snapshot =
      if state.fetching_enabled and state.enabled_reader.() and
           not MapSet.member?(state.invalidated, id),
         do: state.snapshots[id],
         else: nil

    case snapshot do
      %{account: %{active: true} = account, refreshing: false} = snapshot ->
        fetcher = state.fetcher
        owner = Application.get_env(:backplane_monitor, :req_test_owner)

        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            allow_req_test(account.provider, owner)
            safely_fetch(fetcher, account)
          end)

        timer = Process.send_after(self(), {:request_timeout, task.ref}, state.request_timeout)
        task_state = %{task: task, timer: timer, id: id}

        state
        |> Map.update!(:tasks, &Map.put(&1, task.ref, task_state))
        |> put_snapshot(id, %{snapshot | refreshing: true})

      _snapshot ->
        state
    end
  end

  defp safely_fetch(fetcher, account) do
    fetcher.(account)
  rescue
    _exception -> {:error, :refresh_failed}
  catch
    _kind, _reason -> {:error, :refresh_failed}
  end

  defp apply_fetching_policy(state) do
    case state.enabled_reader.() do
      false ->
        state =
          Enum.reduce(state.tasks, state, fn {reference, task}, current ->
            cancel_task(current, reference, task)
          end)

        snapshots =
          Map.new(state.snapshots, fn {id, snapshot} ->
            {id, %{snapshot | refreshing: false}}
          end)

        %{state | fetching_enabled: false, snapshots: snapshots}

      true when not state.fetching_enabled ->
        waiters = if state.definition, do: state.definition.waiters, else: []
        state = cancel_definition_load(state)

        state = %{
          state
          | fetching_enabled: true,
            generation: state.generation + 1,
            invalidated: MapSet.union(state.invalidated, MapSet.new(Map.keys(state.snapshots)))
        }

        load_definitions(state, waiters, true)

      true ->
        state
    end
  end

  defp finish_refresh(state, id, {:ok, usage}) do
    now = DateTime.utc_now()

    snapshot = %{
      state.snapshots[id]
      | usage: usage,
        error: nil,
        fetched_at: now,
        last_success_at: now,
        refreshing: false
    }

    put_snapshot(state, id, snapshot)
  end

  defp finish_refresh(state, id, {:error, reason}) do
    snapshot = %{
      state.snapshots[id]
      | error: reason,
        fetched_at: DateTime.utc_now(),
        refreshing: false
    }

    put_snapshot(state, id, snapshot)
  end

  defp cancel_task(state, reference, task) do
    Process.cancel_timer(task.timer)
    Task.shutdown(task.task, :brutal_kill)
    %{state | tasks: Map.delete(state.tasks, reference)}
  end

  defp put_snapshot(state, id, snapshot) do
    %{state | snapshots: Map.put(state.snapshots, id, snapshot)}
  end

  defp empty_snapshot(account) do
    %{
      account: account,
      usage: nil,
      error: nil,
      fetched_at: nil,
      last_success_at: nil,
      refreshing: false
    }
  end

  defp snapshots(state), do: state.snapshots |> Map.values() |> Enum.sort_by(& &1.account.name)

  defp schedule_poll(%{refresh_interval: interval} = state) when interval > 0 do
    Process.send_after(self(), :poll, interval)
    state
  end

  defp schedule_poll(state), do: state

  defp allow_req_test(_provider, nil), do: :ok

  defp allow_req_test(provider, owner) do
    if Code.ensure_loaded?(Req.Test) do
      stub =
        case provider do
          "openrouter" -> OpenRouter
          "deepseek" -> DeepSeek
          "exa" -> Exa
          "tavily" -> Tavily
          "firecrawl" -> Firecrawl
        end

      Req.Test.allow(stub, owner, self())
    end
  end
end
