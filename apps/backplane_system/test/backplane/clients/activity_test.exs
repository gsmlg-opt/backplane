defmodule Backplane.Clients.ActivityTest do
  use ExUnit.Case, async: true
  alias Backplane.Clients.Activity

  setup do
    supervisor = start_supervised!({Task.Supervisor, []})
    {:ok, time} = Agent.start_link(fn -> 0 end)
    {:ok, writes} = Agent.start_link(fn -> [] end)
    {:ok, source} = Agent.start_link(fn -> MapSet.new(["client", "another", "third"]) end)

    writer =
      start_supervised!(
        {Activity,
         name: nil,
         named_table: false,
         task_supervisor: supervisor,
         activity_capacity: 2,
         activity_batch_size: 1,
         clock: fn -> Agent.get(time, & &1) end,
         now: fn -> DateTime.from_unix!(1_000_000 + Agent.get(time, & &1), :millisecond) end,
         alive: fn id -> Agent.get(source, &MapSet.member?(&1, id)) end,
         persist: fn id, timestamp ->
           Agent.update(writes, &[{id, timestamp} | &1])
           :ok
         end}
      )

    %{
      writer: writer,
      handle: Activity.handle(writer),
      time: time,
      writes: writes,
      source: source,
      supervisor: supervisor
    }
  end

  test "1000 successes coalesce without request tasks or mailbox messages", context do
    for _request <- 1..1_000, do: Activity.record("client", context.handle)
    assert {:message_queue_len, 0} = Process.info(context.writer, :message_queue_len)
    assert :ok = Activity.flush(context.writer)
    assert [{"client", _timestamp}] = Agent.get(context.writes, & &1)
    for _request <- 1..1_000, do: Activity.record("client", context.handle)
    :ok = Activity.flush(context.writer)
    assert length(Agent.get(context.writes, & &1)) == 1
    Agent.update(context.time, fn _ -> 30_000 end)
    Activity.record("client", context.handle)
    :ok = Activity.flush(context.writer)
    assert length(Agent.get(context.writes, & &1)) == 2
  end

  test "latest observation survives a race with flush and retries after failure", context do
    parent = self()

    writer =
      start_supervised!(
        {Activity,
         name: nil,
         named_table: false,
         task_supervisor: context.supervisor,
         clock: fn -> Agent.get(context.time, & &1) end,
         now: fn ->
           DateTime.from_unix!(1_000_000 + Agent.get(context.time, & &1), :millisecond)
         end,
         alive: fn _ -> true end,
         persist: fn _, timestamp ->
           send(parent, {:persist, self(), timestamp})

           receive do: (
                     :ok -> :ok
                     :fail -> raise "database unavailable"
                   )
         end},
        id: make_ref()
      )

    handle = Activity.handle(writer)
    Activity.record("client", handle)
    flushing = Task.async(fn -> Activity.flush(writer) end)
    assert_receive {:persist, worker, _timestamp}
    Agent.update(context.time, fn _ -> 100 end)
    Activity.record("client", handle)
    send(worker, :ok)
    assert :ok = Task.await(flushing)
    assert [{"client", observed, 0}] = :ets.lookup(handle.table, "client")
    assert observed == 1_000_100_000
    Agent.update(context.time, fn _ -> 30_000 end)
    flushing = Task.async(fn -> Activity.flush(writer) end)
    assert_receive {:persist, worker, timestamp}
    assert DateTime.to_unix(timestamp, :microsecond) == observed
    send(worker, :fail)
    assert {:error, :unavailable} = Task.await(flushing)
    assert [{"client", ^observed, 0}] = :ets.lookup(handle.table, "client")
    flushing = Task.async(fn -> Activity.flush(writer) end)
    assert_receive {:persist, worker, ^timestamp}
    send(worker, :ok)
    assert :ok = Task.await(flushing)
    assert [{"client", 0, 30_000}] = :ets.lookup(handle.table, "client")
  end

  test "capacity and batch are bounded and deleted clients are pruned", context do
    for id <- ["client", "another", "third"], do: Activity.record(id, context.handle)
    assert :ets.info(context.handle.table, :size) == 3
    assert :ok = Activity.flush(context.writer)
    assert length(Agent.get(context.writes, & &1)) == 1
    Agent.update(context.source, &MapSet.delete(&1, "client"))
    :ok = Activity.flush(context.writer)
    assert :ets.lookup(context.handle.table, "client") == []
    Activity.record("third", context.handle)
    assert :ets.lookup(context.handle.table, "third") != []
  end
end
