defmodule Backplane.Clients.AuthCacheTest do
  use ExUnit.Case, async: true

  alias Backplane.Clients.{AuthCache, Client}

  setup do
    supervisor = start_supervised!({Task.Supervisor, []})

    {:ok, source} =
      Agent.start_link(fn ->
        [%Client{id: "client", active: true, token_hash: "hash", scopes: ["docs::*"]}]
      end)

    {:ok, clock} = Agent.start_link(fn -> 0 end)
    parent = self()

    cache =
      start_supervised!(
        {AuthCache,
         name: nil,
         task_supervisor: supervisor,
         named_tables: false,
         load: fn -> Agent.get(source, & &1) end,
         clock: fn -> Agent.get(clock, & &1) end,
         refresh_interval_ms: 1_000_000,
         verify: fn token, hash ->
           send(parent, {:bcrypt, token, hash})
           token == "valid"
         end}
      )

    handle = AuthCache.handle(cache)
    assert :ok = AuthCache.refresh(handle)
    %{cache: cache, handle: handle, source: source, clock: clock, supervisor: supervisor}
  end

  test "production warm lookup survives the old TTL and unchanged refresh", context do
    assert {:ok, client} = AuthCache.verify("valid", context.handle)
    assert_receive {:bcrypt, "valid", "hash"}
    Agent.update(context.clock, fn _ -> 61_000 end)
    assert {:error, :unavailable} = AuthCache.verify("valid", context.handle)
    assert :ok = AuthCache.refresh(context.handle)
    assert {:ok, ^client} = AuthCache.verify("valid", context.handle)
    refute_receive {:bcrypt, _, _}
  end

  test "current scopes are authority and late verification cannot resurrect rotation", context do
    assert {:ok, _} = AuthCache.verify("valid", context.handle)
    assert_receive {:bcrypt, _, _}
    [client] = Agent.get(context.source, & &1)
    edited = %{client | scopes: ["git::*"]}
    assert :ok = AuthCache.mutate(context.handle, {:put, edited})
    assert {:ok, verified} = AuthCache.verify("valid", context.handle)
    assert verified.scopes == ["git::*"]
    refute_receive {:bcrypt, _, _}
    assert :ok = AuthCache.mutate(context.handle, {:put, %{edited | active: false}})
    assert :error = AuthCache.verify("valid", context.handle)
  end

  test "unavailable snapshot is protected and oversized secrets never reach bcrypt", context do
    assert AuthCache.any_clients?(context.handle)
    assert :error = AuthCache.verify(String.duplicate("x", 16_385), context.handle)
    refute_receive {:bcrypt, _, _}
  end

  test "refresh reclaims callers that died before submitting an admitted request", context do
    caller = spawn(fn -> :ok end)
    reference = Process.monitor(caller)
    assert_receive {:DOWN, ^reference, :process, ^caller, _reason}
    :ets.insert(context.handle.ingress, {0, make_ref(), caller})
    send(context.cache, :refresh)
    eventually(fn -> assert %{ingress: 0} = AuthCache.stats(context.handle) end)
  end

  test "one cold scan serves concurrent callers; overload never blocks warm traffic", context do
    parent = self()

    cache =
      new_cache(context,
        verify: fn token, _hash ->
          send(parent, {:started, self(), token})
          receive do: (:finish -> token in ["valid", "cold"])
        end,
        max_waiters: 3
      )

    handle = AuthCache.handle(cache)
    :ok = AuthCache.refresh(handle)

    warmup = Task.async(fn -> AuthCache.verify("valid", handle) end)
    assert_receive {:started, worker, "valid"}
    send(worker, :finish)
    assert {:ok, _} = Task.await(warmup)

    first = Task.async(fn -> AuthCache.verify("cold", handle) end)
    assert_receive {:started, worker, "cold"}
    second = Task.async(fn -> AuthCache.verify("cold", handle) end)
    third = Task.async(fn -> AuthCache.verify("cold", handle) end)
    eventually(fn -> assert %{workers: 1, waiters: 3, ingress: 3} = AuthCache.stats(handle) end)
    assert {:error, :overloaded} = AuthCache.verify("different", handle)
    assert {:ok, _} = AuthCache.verify("valid", handle)
    refute_receive {:started, _, _}
    send(worker, :finish)
    assert {:ok, _} = Task.await(first)
    assert {:ok, _} = Task.await(second)
    assert {:ok, _} = Task.await(third)
    assert %{workers: 0, waiters: 0, ingress: 0} = AuthCache.stats(handle)
  end

  test "rotation and disable fence a late worker against the current hash", context do
    parent = self()

    cache =
      new_cache(context,
        verify: fn _token, _hash ->
          send(parent, {:started, self()})
          receive do: (:finish -> true)
        end
      )

    handle = AuthCache.handle(cache)
    :ok = AuthCache.refresh(handle)
    pending = Task.async(fn -> AuthCache.verify("valid", handle) end)
    assert_receive {:started, worker}
    [client] = Agent.get(context.source, & &1)
    :ok = AuthCache.mutate(handle, {:put, %{client | token_hash: "new-hash"}})
    send(worker, :finish)
    assert :error = Task.await(pending)
    assert AuthCache.stats(handle).positives == 0

    pending = Task.async(fn -> AuthCache.verify("valid", handle) end)
    assert_receive {:started, worker}
    :ok = AuthCache.mutate(handle, {:put, %{client | active: false}})
    send(worker, :finish)
    assert :error = Task.await(pending)
  end

  test "older refreshes cannot overwrite a mutation or a newer refresh", context do
    {revision, _loader} = GenServer.call(context.cache, :refresh_ticket)
    [client] = Agent.get(context.source, & &1)
    :ok = AuthCache.mutate(context.handle, {:put, %{client | active: false}})

    assert {:error, :unavailable} =
             GenServer.call(context.cache, {:publish, revision, {:ok, [client], 0}})

    assert :error = AuthCache.verify("valid", context.handle)
    {old_revision, _loader} = GenServer.call(context.cache, :refresh_ticket)
    :ok = AuthCache.refresh(context.handle)

    assert {:error, :unavailable} =
             GenServer.call(context.cache, {:publish, old_revision, {:ok, [], 0}})

    assert AuthCache.any_clients?(context.handle)
  end

  test "failed refresh retains evidence only within the authorization lease", context do
    assert {:ok, _} = AuthCache.verify("valid", context.handle)
    assert_receive {:bcrypt, _, _}
    Agent.update(context.source, fn _ -> :error end)
    Agent.update(context.clock, fn _ -> 29_999 end)
    assert {:error, :unavailable} = AuthCache.refresh(context.handle)
    assert {:ok, _} = AuthCache.verify("valid", context.handle)
    Agent.update(context.clock, fn _ -> 30_000 end)
    assert {:error, :unavailable} = AuthCache.verify("valid", context.handle)
    assert AuthCache.any_clients?(context.handle)
    refute_receive {:bcrypt, _, _}
  end

  test "slow loads cannot extend the lease of an old database snapshot", context do
    parent = self()

    cache =
      new_cache(context,
        clock: fn -> Agent.get(context.clock, & &1) end,
        load: fn ->
          send(parent, {:loading, self()})
          receive do: (:finish -> Agent.get(context.source, & &1))
        end
      )

    handle = AuthCache.handle(cache)
    assert_receive {:loading, worker}
    Agent.update(context.clock, fn _ -> 30_000 end)
    send(worker, :finish)
    eventually(fn -> assert :sys.get_state(cache).refresh == nil end)
    assert AuthCache.any_clients?(handle)
    assert {:error, :unavailable} = AuthCache.verify("valid", handle)
  end

  test "publication and mutation barriers fail closed without discarding unchanged evidence",
       context do
    assert {:ok, _} = AuthCache.verify("valid", context.handle)
    assert_receive {:bcrypt, _, _}
    :ok = AuthCache.begin_mutation(context.handle)
    assert {:error, :unavailable} = AuthCache.verify("valid", context.handle)
    assert {:error, :unavailable} = AuthCache.refresh(context.handle)
    assert AuthCache.any_clients?(context.handle)
    [client] = Agent.get(context.source, & &1)
    :ok = AuthCache.mutate(context.handle, {:put, client})
    assert {:ok, _} = AuthCache.verify("valid", context.handle)
    refute_receive {:bcrypt, _, _}
  end

  test "positive capacity is independent of unique invalid traffic", context do
    cache =
      new_cache(context,
        positive_capacity: 2,
        verify: fn token, _hash -> String.starts_with?(token, "valid") end
      )

    handle = AuthCache.handle(cache)
    :ok = AuthCache.refresh(handle)

    for token <- ["valid-1", "valid-2", "valid-3"],
        do: assert({:ok, _} = AuthCache.verify(token, handle))

    evidence = :ets.tab2list(handle.evidence)
    for number <- 1..100, do: assert(:error = AuthCache.verify("invalid-#{number}", handle))
    assert AuthCache.stats(handle).positives == 2
    assert :ets.tab2list(handle.evidence) == evidence
    refute inspect(evidence) =~ "valid"
  end

  test "negative hits are direct, bounded, expire, and cannot hide creation", context do
    parent = self()

    cache =
      new_cache(context,
        negative_capacity: 2,
        clock: fn -> Agent.get(context.clock, & &1) end,
        verify: fn token, hash ->
          send(parent, {:bcrypt, token, hash})
          token == "valid"
        end
      )

    handle = AuthCache.handle(cache)
    :ok = AuthCache.refresh(handle)
    assert :error = AuthCache.verify("missing", handle)
    assert_receive {:bcrypt, "missing", "hash"}
    assert :ok = AuthCache.refresh(handle)
    assert :error = AuthCache.verify("missing", handle)
    refute_receive {:bcrypt, _, _}
    Agent.update(context.clock, fn _ -> 5_000 end)
    assert :error = AuthCache.verify("missing", handle)
    assert_receive {:bcrypt, "missing", "hash"}

    for token <- ["another", "third"], do: assert(:error = AuthCache.verify(token, handle))
    assert %{negatives: 2} = AuthCache.stats(handle)
    [client] = Agent.get(context.source, & &1)
    assert :ok = AuthCache.mutate(handle, {:delete, client.id})
    assert :error = AuthCache.verify("valid", handle)
    assert :ok = AuthCache.mutate(handle, {:put, %{client | token_hash: "new-hash"}})
    assert {:ok, _client} = AuthCache.verify("valid", handle)
    assert %{negatives: 0} = AuthCache.stats(handle)
  end

  test "deadline keeps the permit until the supervised worker actually exits", context do
    parent = self()

    cache =
      new_cache(context,
        verification_timeout_ms: 50,
        verify: fn _, _ ->
          send(parent, {:started, self()})
          receive do: (:finish -> true)
        end
      )

    handle = AuthCache.handle(cache)
    :ok = AuthCache.refresh(handle)
    pending = Task.async(fn -> AuthCache.verify("cold", handle) end)
    assert_receive {:started, worker}
    reference = Process.monitor(worker)
    assert {:error, :unavailable} = Task.await(pending)
    assert Process.alive?(worker)
    assert %{workers: 1, waiters: 0, ingress: 0} = AuthCache.stats(handle)
    assert {:error, :overloaded} = AuthCache.verify("other", handle)
    send(worker, :finish)
    assert_receive {:DOWN, ^reference, :process, ^worker, :normal}
    eventually(fn -> assert %{workers: 0, waiters: 0, ingress: 0} = AuthCache.stats(handle) end)
  end

  test "dead waiters and failed workers release bounded admission tickets", context do
    parent = self()

    cache =
      new_cache(context,
        verify: fn _, _ ->
          send(parent, {:started, self()})
          receive do: (:crash -> exit(:verification_failed))
        end
      )

    handle = AuthCache.handle(cache)
    :ok = AuthCache.refresh(handle)
    caller = spawn(fn -> AuthCache.verify("cold", handle) end)
    assert_receive {:started, worker}
    Process.exit(caller, :kill)
    eventually(fn -> assert %{workers: 1, waiters: 0, ingress: 0} = AuthCache.stats(handle) end)
    send(worker, :crash)
    eventually(fn -> assert %{workers: 0} = AuthCache.stats(handle) end)
  end

  test "unknown empty state stays protected until an authoritative empty load", context do
    cache = new_cache(context, load: fn -> :error end)
    handle = AuthCache.handle(cache)
    assert {:error, :unavailable} = AuthCache.refresh(handle)
    assert AuthCache.any_clients?(handle)
    assert {:error, :unavailable} = AuthCache.verify("valid", handle)
    {revision, _loader} = GenServer.call(cache, :refresh_ticket)
    assert :ok = GenServer.call(cache, {:publish, revision, {:ok, [], context.handle.clock.()}})
    refute AuthCache.any_clients?(handle)
  end

  test "remote invalidation blocks stale authorization immediately even when reload fails",
       context do
    assert {:ok, _client} = AuthCache.verify("valid", context.handle)
    assert_receive {:bcrypt, _, _}
    Agent.update(context.source, fn _ -> :error end)
    send(context.cache, {:client_auth_invalidated, :other@node, "client"})
    GenServer.call(context.cache, :stats)
    assert {:error, :unavailable} = AuthCache.verify("valid", context.handle)
    assert AuthCache.any_clients?(context.handle)

    Agent.update(context.source, fn _ ->
      [%Client{id: "client", token_hash: "hash", active: false}]
    end)

    :ok = AuthCache.refresh(context.handle)
    assert :error = AuthCache.verify("valid", context.handle)
  end

  test "unchanged refresh during a scan does not turn a genuine miss into unavailable", context do
    parent = self()

    cache =
      new_cache(context,
        verify: fn _, _ ->
          send(parent, {:started, self()})
          receive do: (:finish -> false)
        end
      )

    handle = AuthCache.handle(cache)
    :ok = AuthCache.refresh(handle)
    pending = Task.async(fn -> AuthCache.verify("invalid", handle) end)
    assert_receive {:started, worker}
    :ok = AuthCache.refresh(handle)
    send(worker, :finish)
    assert :error = Task.await(pending)
  end

  defp new_cache(context, opts) do
    defaults = [
      name: nil,
      named_tables: false,
      task_supervisor: context.supervisor,
      refresh_interval_ms: 1_000_000,
      load: fn -> Agent.get(context.source, & &1) end
    ]

    start_supervised!({AuthCache, Keyword.merge(defaults, opts)}, id: make_ref())
  end

  defp eventually(assertion, attempts \\ 100) do
    assertion.()
  rescue
    error in ExUnit.AssertionError ->
      if attempts == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(5)
      eventually(assertion, attempts - 1)
  end
end
