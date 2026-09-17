defmodule Backplane.Monitor.ApiUsageServerTest do
  use ExUnit.Case, async: true

  alias Backplane.Monitor.{ApiAccount, ApiUsageServer}

  setup do
    supervisor = start_supervised!(Task.Supervisor)
    %{task_supervisor: supervisor}
  end

  test "refreshes asynchronously without overlapping calls and caches success", context do
    owner = self()

    fetcher = fn account ->
      send(owner, {:fetch_started, self(), account.id})

      receive do
        {:result, result} -> result
      end
    end

    server = server(context, fetcher)
    account = account()
    assert [%{refreshing: true, usage: nil}] = ApiUsageServer.sync(server, [account])
    assert_receive {:fetch_started, worker, id}
    assert id == account.id
    assert :ok = ApiUsageServer.refresh(server, account.id)
    refute_receive {:fetch_started, _, _}, 30

    send(worker, {:result, {:ok, data()}})
    snapshot = await_state(server, account.id, &(!&1.refreshing))
    assert snapshot.usage == data()
    assert snapshot.last_success_at
    assert snapshot.fetched_at
    assert snapshot.error == nil
  end

  test "keeps last successful values and timestamp after a safe error", context do
    counter = start_supervised!({Agent, fn -> 0 end})

    fetcher = fn _account ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:ok, data()}
        _ -> {:error, {:http_error, 401}}
      end
    end

    server = server(context, fetcher)
    account = account()
    ApiUsageServer.sync(server, [account])
    successful = await_state(server, account.id, &(!&1.refreshing))
    ApiUsageServer.refresh(server, account.id)
    failed = await_state(server, account.id, &(!&1.refreshing and &1.error != nil))
    assert failed.usage == successful.usage
    assert failed.last_success_at == successful.last_success_at
    assert failed.error == {:http_error, 401}
  end

  test "invalidates old work and values when the credential changes or account is removed",
       context do
    owner = self()

    fetcher = fn account ->
      send(owner, {:fetch_started, self(), account.credential_name})

      receive do
        {:result, result} -> result
      end
    end

    server = server(context, fetcher)
    account = account()
    ApiUsageServer.sync(server, [account])
    assert_receive {:fetch_started, old_worker, "key"}
    monitor = Process.monitor(old_worker)
    updated = %{account | credential_name: "new-key"}
    assert [%{usage: nil, refreshing: true}] = ApiUsageServer.sync(server, [updated])
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}
    assert_receive {:fetch_started, new_worker, "new-key"}

    send(old_worker, {:result, {:ok, data()}})
    assert [%{account: ^updated, usage: nil}] = ApiUsageServer.states(server)
    assert [] = ApiUsageServer.sync(server, [])
    refute Process.alive?(new_worker)
  end

  test "paused accounts never fetch and pause cancels in-flight results", context do
    owner = self()

    fetcher = fn _ ->
      send(owner, {:fetch_started, self()})

      receive do
        :release -> {:ok, data()}
      end
    end

    server = server(context, fetcher)
    account = account()
    ApiUsageServer.sync(server, [account])
    assert_receive {:fetch_started, worker}
    paused = %{account | active: false}

    assert [%{account: ^paused, refreshing: false, usage: nil}] =
             ApiUsageServer.sync(server, [paused])

    refute Process.alive?(worker)
    assert :ok = ApiUsageServer.refresh(server, paused.id)
    refute_receive {:fetch_started, _}, 30
  end

  test "task crashes become a safe error without exposing their reason", context do
    fetcher = fn _ -> exit({:remote_error, "super-secret-api-key"}) end
    server = server(context, fetcher)
    account = account()
    ApiUsageServer.sync(server, [account])
    snapshot = await_state(server, account.id, &(!&1.refreshing))
    assert snapshot.error == :refresh_failed
    refute inspect(snapshot) =~ "super-secret-api-key"
  end

  test "times out a stalled fetch, stops its task, and allows a later retry", context do
    owner = self()

    fetcher = fn _ ->
      send(owner, {:fetch_started, self()})

      receive do
        {:result, result} -> result
      end
    end

    server =
      start_supervised!(
        {ApiUsageServer,
         name: nil,
         task_supervisor: context.task_supervisor,
         fetcher: fetcher,
         refresh_interval: 0,
         request_timeout: 100}
      )

    account = account()
    ApiUsageServer.sync(server, [account])
    assert_receive {:fetch_started, worker}
    failed = await_state(server, account.id, &(!&1.refreshing))
    assert failed.error == :request_timeout
    assert failed.last_success_at == nil
    refute Process.alive?(worker)

    ApiUsageServer.refresh(server, account.id)
    assert_receive {:fetch_started, retry_worker}
    send(retry_worker, {:result, {:ok, data()}})
    assert %{error: nil, usage: usage} = await_state(server, account.id, &(!&1.refreshing))
    assert usage == data()
  end

  test "ignores unknown late responses and timeout messages", context do
    server = server(context, fn _ -> {:ok, data()} end)
    send(server, {make_ref(), {:ok, %{usage: "stale"}}})
    send(server, {:request_timeout, make_ref()})
    assert ApiUsageServer.states(server) == []
  end

  test "definition loading cannot restore a paused definition after a concurrent update",
       context do
    owner = self()

    loader = fn ->
      send(owner, {:loading, self()})

      receive do
        {:definitions, accounts} -> accounts
      end
    end

    fetcher = fn _ ->
      send(owner, :unexpected_fetch)
      {:ok, data()}
    end

    server =
      start_supervised!(
        {ApiUsageServer,
         name: nil,
         task_supervisor: context.task_supervisor,
         fetcher: fetcher,
         account_loader: loader,
         refresh_interval: 0}
      )

    loading = Task.async(fn -> ApiUsageServer.load_states(server) end)
    assert_receive {:loading, first_loader}
    active = account()
    paused = %{active | active: false}
    ApiUsageServer.definition_changed(server, paused.id)
    assert [] = ApiUsageServer.states(server)
    send(first_loader, {:definitions, [active]})
    assert_receive {:loading, next_loader}
    send(next_loader, {:definitions, [paused]})
    assert [%{account: ^paused, refreshing: false}] = Task.await(loading)
    refute_receive :unexpected_fetch, 30
  end

  test "failed and stalled definition loading preserve cached values and leave the server responsive",
       context do
    owner = self()

    loader = fn ->
      send(owner, {:loading, self()})

      receive do
        :fail -> raise "database failure"
      end
    end

    server =
      start_supervised!(
        {ApiUsageServer,
         name: nil,
         task_supervisor: context.task_supervisor,
         fetcher: fn _ -> {:ok, data()} end,
         account_loader: loader,
         refresh_interval: 0,
         definition_timeout: 100}
      )

    account = account()
    ApiUsageServer.sync(server, [account])
    successful = await_state(server, account.id, &(!&1.refreshing))
    loading = Task.async(fn -> ApiUsageServer.load_states(server) end)
    assert_receive {:loading, worker}
    assert [^successful] = ApiUsageServer.states(server)
    send(worker, :fail)
    assert [^successful] = Task.await(loading)

    stalled = Task.async(fn -> ApiUsageServer.load_states(server) end)
    assert_receive {:loading, stalled_worker}
    assert [^successful] = ApiUsageServer.states(server)
    assert [^successful] = Task.await(stalled)
    refute Process.alive?(stalled_worker)
  end

  test "definition invalidation retains success and blocks polling until definitions recover",
       context do
    owner = self()

    loader = fn ->
      send(owner, {:loading, self()})

      receive do
        :fail -> raise "database failure"
        {:definitions, accounts} -> accounts
      end
    end

    fetcher = fn _ ->
      send(owner, :fetched)
      {:ok, data()}
    end

    server =
      start_supervised!(
        {ApiUsageServer,
         name: nil,
         task_supervisor: context.task_supervisor,
         fetcher: fetcher,
         account_loader: loader,
         refresh_interval: 0}
      )

    account = account()
    ApiUsageServer.sync(server, [account])
    successful = await_state(server, account.id, &(!&1.refreshing))
    assert_receive :fetched
    ApiUsageServer.definition_changed(server, account.id)
    assert_receive {:loading, worker}
    send(worker, :fail)
    assert [^successful] = ApiUsageServer.states(server)
    ApiUsageServer.refresh(server, account.id)
    ApiUsageServer.refresh_all(server)
    refute_receive :fetched, 30

    loading = Task.async(fn -> ApiUsageServer.load_states(server) end)
    assert_receive {:loading, next_worker}
    paused = %{account | name: "Renamed", active: false}
    send(next_worker, {:definitions, [paused]})
    assert [%{account: ^paused, usage: usage, last_success_at: timestamp}] = Task.await(loading)
    assert usage == successful.usage
    assert timestamp == successful.last_success_at
    refute_receive :fetched, 30
  end

  test "waiting reads expire across repeated definition generations", context do
    owner = self()

    loader = fn ->
      send(owner, {:loading, self()})

      receive do
        :finish -> []
      end
    end

    server =
      start_supervised!(
        {ApiUsageServer,
         name: nil,
         task_supervisor: context.task_supervisor,
         account_loader: loader,
         refresh_interval: 0,
         waiter_timeout: 100}
      )

    loading = Task.async(fn -> ApiUsageServer.load_states(server) end)
    assert_receive {:loading, first_worker}
    ApiUsageServer.definition_changed(server, Ecto.UUID.generate())
    send(first_worker, :finish)
    assert_receive {:loading, second_worker}
    ApiUsageServer.definition_changed(server, Ecto.UUID.generate())
    send(second_worker, :finish)
    assert_receive {:loading, _third_worker}
    assert Task.yield(loading, 500) == {:ok, []}
    assert %{definition: %{waiters: []}} = :sys.get_state(server)
  end

  test "disabled fetching blocks initial, manual, periodic, and definition refresh", context do
    owner = self()
    account = account()

    server =
      start_supervised!(
        {ApiUsageServer,
         name: nil,
         task_supervisor: context.task_supervisor,
         enabled_reader: fn -> false end,
         account_loader: fn -> [account] end,
         fetcher: fn _ ->
           send(owner, :unexpected_fetch)
           {:ok, data()}
         end,
         refresh_interval: 0}
      )

    assert [%{refreshing: false}] = ApiUsageServer.sync(server, [account])
    ApiUsageServer.refresh(server, account.id)
    ApiUsageServer.refresh_all(server)
    send(server, :poll)
    assert [%{refreshing: false}] = ApiUsageServer.load_states(server)
    ApiUsageServer.definition_changed(server, account.id)
    assert [%{refreshing: false}] = ApiUsageServer.load_states(server)
    refute_receive :unexpected_fetch, 30
  end

  test "disabling cancels in-flight refresh and preserves the last successful values", context do
    owner = self()
    enabled = start_supervised!({Agent, fn -> true end})

    fetcher = fn _ ->
      send(owner, {:fetch_started, self()})

      receive do
        {:result, result} -> result
      end
    end

    server =
      start_supervised!(
        {ApiUsageServer,
         name: nil,
         task_supervisor: context.task_supervisor,
         enabled_reader: fn -> Agent.get(enabled, & &1) end,
         fetcher: fetcher,
         refresh_interval: 0}
      )

    account = account()
    ApiUsageServer.sync(server, [account])
    assert_receive {:fetch_started, first_worker}
    send(first_worker, {:result, {:ok, data()}})
    successful = await_state(server, account.id, &(!&1.refreshing))
    ApiUsageServer.refresh(server, account.id)
    assert_receive {:fetch_started, stalled_worker}
    Agent.update(enabled, fn _ -> false end)
    assert :ok = ApiUsageServer.reload_fetching_policy(server)
    refute Process.alive?(stalled_worker)
    assert [^successful] = ApiUsageServer.states(server)
    send(server, {make_ref(), {:ok, %{usage: "late"}}})
    ApiUsageServer.refresh(server, account.id)
    ApiUsageServer.refresh_all(server)
    assert [^successful] = ApiUsageServer.states(server)
    refute_receive {:fetch_started, _}, 30
  end

  test "settings notifications cancel work and re-enable refreshes authoritative active accounts",
       context do
    owner = self()
    enabled = start_supervised!({Agent, fn -> true end})
    old = account()
    current = %{old | credential_name: "updated-key"}
    paused = %{account() | active: false}
    deleted = account()

    server =
      start_supervised!(
        {ApiUsageServer,
         name: nil,
         task_supervisor: context.task_supervisor,
         enabled_reader: fn -> Agent.get(enabled, & &1) end,
         account_loader: fn -> [current, paused] end,
         fetcher: fn definition ->
           send(owner, {:fetch_started, self(), definition.credential_name})

           receive do
             {:result, result} -> result
           end
         end,
         refresh_interval: 0}
      )

    ApiUsageServer.sync(server, [old])
    assert_receive {:fetch_started, worker, "key"}
    Agent.update(enabled, fn _ -> false end)
    send(server, {:setting_changed, "monitor.api_usage.enabled", false})
    assert [%{refreshing: false}] = ApiUsageServer.states(server)
    refute Process.alive?(worker)
    ApiUsageServer.sync(server, [old, deleted])
    Agent.update(enabled, fn _ -> true end)
    assert :ok = ApiUsageServer.reload_fetching_policy(server)
    assert_receive {:fetch_started, current_worker, "updated-key"}
    send(current_worker, {:result, {:ok, data()}})
    await_state(server, current.id, &(!&1.refreshing))

    assert Enum.map(ApiUsageServer.states(server), & &1.account.id) |> Enum.sort() ==
             Enum.sort([current.id, paused.id])

    refute_receive {:fetch_started, _, _}, 30
  end

  test "fetch starts obey current settings even before their notification is processed",
       context do
    owner = self()
    enabled = start_supervised!({Agent, fn -> true end})

    server =
      start_supervised!(
        {ApiUsageServer,
         name: nil,
         task_supervisor: context.task_supervisor,
         enabled_reader: fn -> Agent.get(enabled, & &1) end,
         fetcher: fn _ ->
           send(owner, :fetched)
           {:ok, data()}
         end,
         refresh_interval: 0}
      )

    account = account()
    ApiUsageServer.sync(server, [account])
    successful = await_state(server, account.id, &(!&1.refreshing))
    assert_receive :fetched
    Agent.update(enabled, fn _ -> false end)
    ApiUsageServer.refresh(server, account.id)
    assert [^successful] = ApiUsageServer.states(server)
    refute_receive :fetched, 30
  end

  test "re-enable blocks cached definitions until a successful authoritative reload", context do
    owner = self()
    enabled = start_supervised!({Agent, fn -> true end})
    account = account()

    loader = fn ->
      send(owner, {:loading, self()})

      receive do
        :fail -> raise "database unavailable"
        {:definitions, definitions} -> definitions
      end
    end

    server =
      start_supervised!(
        {ApiUsageServer,
         name: nil,
         task_supervisor: context.task_supervisor,
         enabled_reader: fn -> Agent.get(enabled, & &1) end,
         account_loader: loader,
         fetcher: fn _ ->
           send(owner, :fetched)
           {:ok, data()}
         end,
         refresh_interval: 0}
      )

    ApiUsageServer.sync(server, [account])
    successful = await_state(server, account.id, &(!&1.refreshing))
    assert_receive :fetched
    Agent.update(enabled, fn _ -> false end)
    ApiUsageServer.reload_fetching_policy(server)
    Agent.update(enabled, fn _ -> true end)
    ApiUsageServer.reload_fetching_policy(server)
    assert_receive {:loading, worker}
    ApiUsageServer.refresh(server, account.id)
    ApiUsageServer.refresh_all(server)
    refute_receive :fetched, 30
    send(worker, :fail)
    assert [^successful] = ApiUsageServer.states(server)
    ApiUsageServer.refresh(server, account.id)
    refute_receive :fetched, 30

    loading = Task.async(fn -> ApiUsageServer.load_states(server) end)
    assert_receive {:loading, next_worker}
    paused = %{account | active: false}
    send(next_worker, {:definitions, [paused]})
    assert [%{account: ^paused, refreshing: false}] = Task.await(loading)
    refute_receive :fetched, 30
  end

  test "re-enable replaces an older definition read while preserving waiting callers", context do
    owner = self()
    enabled = start_supervised!({Agent, fn -> false end})
    account = account()

    server =
      start_supervised!(
        {ApiUsageServer,
         name: nil,
         task_supervisor: context.task_supervisor,
         enabled_reader: fn -> Agent.get(enabled, & &1) end,
         account_loader: fn ->
           send(owner, {:loading, self()})

           receive do
             {:definitions, definitions} -> definitions
           end
         end,
         fetcher: fn _ ->
           send(owner, :unexpected_fetch)
           {:ok, data()}
         end,
         refresh_interval: 0}
      )

    ApiUsageServer.sync(server, [account])
    loading = Task.async(fn -> ApiUsageServer.load_states(server) end)
    assert_receive {:loading, old_worker}
    Agent.update(enabled, fn _ -> true end)
    ApiUsageServer.reload_fetching_policy(server)
    refute Process.alive?(old_worker)
    assert_receive {:loading, fresh_worker}
    paused = %{account | active: false}
    send(fresh_worker, {:definitions, [paused]})
    assert [%{account: ^paused, refreshing: false}] = Task.await(loading)
    refute_receive :unexpected_fetch, 30
  end

  defp server(context, fetcher) do
    start_supervised!(
      {ApiUsageServer,
       name: nil, task_supervisor: context.task_supervisor, fetcher: fetcher, refresh_interval: 0}
    )
  end

  defp account do
    %ApiAccount{
      id: Ecto.UUID.generate(),
      name: "Test",
      provider: "openrouter",
      credential_name: "key",
      active: true
    }
  end

  defp data, do: %{balances: [], usage: [], warnings: []}

  defp await_state(server, id, predicate, attempts \\ 100)
  defp await_state(_server, _id, _predicate, 0), do: flunk("refresh did not finish")

  defp await_state(server, id, predicate, attempts) do
    snapshot = Enum.find(ApiUsageServer.states(server), &(&1.account.id == id))

    if predicate.(snapshot) do
      snapshot
    else
      Process.sleep(10)
      await_state(server, id, predicate, attempts - 1)
    end
  end
end
