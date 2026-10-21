defmodule Backplane.Clients.AuthCacheTest do
  use ExUnit.Case, async: true

  alias Backplane.Clients.{AuthCache, Client}

  setup do
    supervisor = start_supervised!({Task.Supervisor, []})
    token = token()
    client = %Client{id: "client", active: true, token_digest: digest(token), scopes: ["docs::*"]}
    {:ok, source} = Agent.start_link(fn -> [client] end)
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    cache =
      start_supervised!(
        {AuthCache,
         name: nil,
         task_supervisor: supervisor,
         named_tables: false,
         load: fn -> Agent.get(source, & &1) end,
         clock: fn -> Agent.get(clock, & &1) end,
         refresh_interval_ms: 1_000_000}
      )

    handle = AuthCache.handle(cache)
    assert :ok = AuthCache.refresh(handle)

    %{
      cache: cache,
      handle: handle,
      source: source,
      clock: clock,
      supervisor: supervisor,
      token: token,
      client: client
    }
  end

  test "first success and unique misses read indexes without owner or loader", context do
    :sys.suspend(context.cache)
    :sys.suspend(context.source)

    try do
      assert {:ok, true} = AuthCache.fetch_any_clients(context.handle)
      assert {:ok, client} = AuthCache.verify(context.token, context.handle)
      assert client.id == context.client.id
      for _ <- 1..1_000, do: assert(:error = AuthCache.verify(token(), context.handle))
      assert :ets.info(context.handle.digests, :size) == 1
      assert :ets.info(context.handle.clients, :size) == 1
      refute Map.has_key?(context.handle, :evidence)
      refute Map.has_key?(context.handle, :negatives)
      assert {:message_queue_len, 0} = Process.info(context.cache, :message_queue_len)
      assert Task.Supervisor.children(context.supervisor) == []
    after
      :sys.resume(context.source)
      :sys.resume(context.cache)
    end
  end

  test "request index work has a fixed bound for one and ten thousand clients", c do
    for count <- [1, 10_000] do
      clients =
        for n <- 1..count do
          %{
            c.client
            | id: "client-#{n}",
              token_digest: if(n == 1, do: c.client.token_digest, else: digest(token()))
          }
        end

      Agent.update(c.source, fn _ -> clients end)
      assert :ok = AuthCache.refresh(c.handle)

      assert indexed_lookup_counts(
               fn ->
                 assert {:ok, _} = AuthCache.verify(c.token, c.handle)
                 assert :error = AuthCache.verify(token(), c.handle)
               end,
               c.handle
             ) == %{digest: 2, client: 1, control: 4, scan: 0}
    end
  end

  test "current scopes, active state, rotation, revoke and deletion are authoritative", c do
    edited = %{c.client | scopes: ["git::*"]}
    assert :ok = AuthCache.mutate(c.handle, {:put, edited})
    assert {:ok, ^edited} = AuthCache.verify(c.token, c.handle)
    replacement = token()
    rotated = %{edited | token_digest: digest(replacement)}
    assert :ok = AuthCache.mutate(c.handle, {:put, rotated})
    assert :error = AuthCache.verify(c.token, c.handle)
    assert {:ok, ^rotated} = AuthCache.verify(replacement, c.handle)
    assert :ok = AuthCache.mutate(c.handle, {:put, %{rotated | active: false}})
    assert :error = AuthCache.verify(replacement, c.handle)
    assert AuthCache.stats(c.handle).digests == 0
    assert :ok = AuthCache.mutate(c.handle, {:put, %{rotated | token_digest: nil}})
    assert :error = AuthCache.verify(replacement, c.handle)
    assert AuthCache.any_clients?(c.handle)
    assert {:ok, true} = AuthCache.fetch_any_clients(c.handle)
    assert :ok = AuthCache.mutate(c.handle, {:delete, rotated.id})
    refute AuthCache.any_clients?(c.handle)
    assert {:ok, false} = AuthCache.fetch_any_clients(c.handle)
  end

  test "malformed, old and noncanonical tokens cannot authenticate", c do
    for invalid <- [
          nil,
          "",
          "old-token",
          "bp2_" <> String.duplicate("x", 44),
          "bp2_" <> String.duplicate("!", 43),
          String.duplicate("x", 16_385)
        ] do
      assert :error = AuthCache.verify(invalid, c.handle)
    end

    assert AuthCache.token_format_valid?(c.token)
    refute AuthCache.token_format_valid?(String.slice(c.token, 0, 46) <> "B")
  end

  test "lease expires and unchanged refresh restores direct lookup", c do
    assert {:ok, _} = AuthCache.verify(c.token, c.handle)
    assert {:ok, true} = AuthCache.fetch_any_clients(c.handle)
    Agent.update(c.clock, fn _ -> 30_000 end)
    assert {:error, :unavailable} = AuthCache.verify(c.token, c.handle)
    assert {:error, :unavailable} = AuthCache.verify(token(), c.handle)
    assert AuthCache.any_clients?(c.handle)
    assert {:error, :unavailable} = AuthCache.fetch_any_clients(c.handle)
    assert :ok = AuthCache.refresh(c.handle)
    assert {:ok, _} = AuthCache.verify(c.token, c.handle)
    assert {:ok, true} = AuthCache.fetch_any_clients(c.handle)
  end

  test "failed refresh cannot extend last authorization lease", c do
    Agent.update(c.source, fn _ -> :error end)
    Agent.update(c.clock, fn _ -> 29_999 end)
    assert {:error, :unavailable} = AuthCache.refresh(c.handle)
    assert {:ok, _} = AuthCache.verify(c.token, c.handle)
    assert {:ok, true} = AuthCache.fetch_any_clients(c.handle)
    Agent.update(c.clock, fn _ -> 30_000 end)
    assert {:error, :unavailable} = AuthCache.verify(c.token, c.handle)
    assert {:error, :unavailable} = AuthCache.fetch_any_clients(c.handle)
  end

  test "older refresh cannot overwrite mutation or newer refresh", c do
    {revision, _} = GenServer.call(c.cache, :refresh_ticket)
    assert :ok = AuthCache.mutate(c.handle, {:put, %{c.client | token_digest: nil}})

    assert {:error, :unavailable} =
             GenServer.call(c.cache, {:publish, revision, {:ok, [c.client], 0}})

    assert :error = AuthCache.verify(c.token, c.handle)
    {old_revision, _} = GenServer.call(c.cache, :refresh_ticket)
    assert :ok = AuthCache.refresh(c.handle)

    assert {:error, :unavailable} =
             GenServer.call(c.cache, {:publish, old_revision, {:ok, [], 0}})

    assert AuthCache.any_clients?(c.handle)
  end

  test "mutation barrier prevents authorization and refresh until publication", c do
    assert :ok = AuthCache.begin_mutation(c.handle)
    assert {:error, :unavailable} = AuthCache.verify(c.token, c.handle)
    assert {:error, :unavailable} = AuthCache.refresh(c.handle)
    assert AuthCache.any_clients?(c.handle)
    assert {:error, :unavailable} = AuthCache.fetch_any_clients(c.handle)
    assert :ok = AuthCache.mutate(c.handle, {:put, c.client})
    assert {:ok, _} = AuthCache.verify(c.token, c.handle)
    assert {:ok, true} = AuthCache.fetch_any_clients(c.handle)
  end

  test "aborted and dead mutation writers remain fail closed until reload", c do
    assert :ok = AuthCache.begin_mutation(c.handle)
    assert :ok = AuthCache.abort_mutation(c.handle)
    assert {:error, :unavailable} = AuthCache.verify(c.token, c.handle)
    assert :ok = AuthCache.refresh(c.handle)
    parent = self()

    writer =
      spawn(fn ->
        AuthCache.begin_mutation(c.handle)
        send(parent, :blocked)
      end)

    assert_receive :blocked
    eventually(fn -> refute :sys.get_state(c.cache).blocked end)
    refute Process.alive?(writer)
    assert {:error, :unavailable} = AuthCache.verify(c.token, c.handle)
  end

  test "slow loads count their lease from before database query", c do
    parent = self()

    cache =
      new_cache(c,
        load: fn ->
          send(parent, {:loading, self()})
          receive do: (:finish -> [c.client])
        end
      )

    handle = AuthCache.handle(cache)
    assert_receive {:loading, worker}
    Agent.update(c.clock, fn _ -> 30_000 end)
    send(worker, :finish)
    eventually(fn -> assert :sys.get_state(cache).refresh == nil end)
    assert {:error, :unavailable} = AuthCache.verify(c.token, handle)
  end

  test "unknown empty state stays protected until authoritative empty load", c do
    cache = new_cache(c, load: fn -> :error end)
    handle = AuthCache.handle(cache)
    assert {:error, :unavailable} = AuthCache.refresh(handle)
    assert AuthCache.any_clients?(handle)
    assert {:error, :unavailable} = AuthCache.fetch_any_clients(handle)
    assert {:error, :unavailable} = AuthCache.verify(c.token, handle)
    {revision, _} = GenServer.call(cache, :refresh_ticket)
    assert :ok = GenServer.call(cache, {:publish, revision, {:ok, [], 0}})
    refute AuthCache.any_clients?(handle)
    assert {:ok, false} = AuthCache.fetch_any_clients(handle)
  end

  test "remote invalidation blocks stale state even when reload fails", c do
    Agent.update(c.source, fn _ -> :error end)
    send(c.cache, {:client_auth_invalidated, :other@node, c.client.id})
    AuthCache.stats(c.handle)
    assert {:error, :unavailable} = AuthCache.verify(c.token, c.handle)
    assert AuthCache.any_clients?(c.handle)
    assert {:error, :unavailable} = AuthCache.fetch_any_clients(c.handle)
    Agent.update(c.source, fn _ -> [%{c.client | active: false}] end)
    assert :ok = AuthCache.refresh(c.handle)
    assert :error = AuthCache.verify(c.token, c.handle)
    assert {:ok, true} = AuthCache.fetch_any_clients(c.handle)
  end

  test "restart invalidates old handles and reload creates a new incarnation", c do
    assert {:ok, _} = AuthCache.verify(c.token, c.handle)
    old_control = c.handle.control
    cache = new_cache(c)
    handle = AuthCache.handle(cache)
    assert :ok = AuthCache.refresh(handle)
    assert handle.control != old_control
    GenServer.stop(c.cache)
    assert {:error, :unavailable} = AuthCache.verify(c.token, c.handle)
    assert AuthCache.any_clients?(c.handle)
    assert {:error, :unavailable} = AuthCache.fetch_any_clients(c.handle)
    assert {:ok, _} = AuthCache.verify(c.token, handle)
    assert {:ok, true} = AuthCache.fetch_any_clients(handle)
  end

  defp indexed_lookup_counts(fun, handle) do
    parent = self()

    tracer =
      spawn(fn ->
        collect_lookups(parent, handle, %{digest: 0, client: 0, control: 0, scan: 0})
      end)

    :erlang.trace_pattern({:ets, :lookup, 2}, true, [])
    :erlang.trace_pattern({:ets, :tab2list, 1}, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
      reference = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^reference}
      send(tracer, :read)
      assert_receive {:lookup_counts, ^tracer, counts}
      counts
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({:ets, :lookup, 2}, false, [])
      :erlang.trace_pattern({:ets, :tab2list, 1}, false, [])
      send(tracer, :stop)
    end
  end

  defp collect_lookups(parent, handle, counts) do
    receive do
      :read ->
        send(parent, {:lookup_counts, self(), counts})
        collect_lookups(parent, handle, counts)

      :stop ->
        :ok

      {:trace, _, :call, {:ets, :lookup, [table, _]}} ->
        key =
          cond do
            table == handle.digests -> :digest
            table == handle.clients -> :client
            table == handle.control -> :control
            true -> nil
          end

        collect_lookups(
          parent,
          handle,
          if(key, do: Map.update!(counts, key, &(&1 + 1)), else: counts)
        )

      {:trace, _, :call, {:ets, :tab2list, _}} ->
        collect_lookups(parent, handle, Map.update!(counts, :scan, &(&1 + 1)))

      _ ->
        collect_lookups(parent, handle, counts)
    end
  end

  defp token, do: "bp2_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp digest(token), do: :crypto.hash(:sha256, token)

  defp new_cache(c, opts \\ []) do
    defaults = [
      name: nil,
      named_tables: false,
      task_supervisor: c.supervisor,
      clock: fn -> Agent.get(c.clock, & &1) end,
      refresh_interval_ms: 1_000_000,
      load: fn -> Agent.get(c.source, & &1) end
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
