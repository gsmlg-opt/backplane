defmodule Backplane.AgentRuntime.NotificationLifecycleTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error}

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule GatedStore do
    defdelegate mode(), to: EphemeralStore
    defdelegate capabilities(), to: EphemeralStore

    def store(context, run, meta) do
      case :ets.take(context.gates, :next_write) do
        [{_, :reject}] ->
          {:error, Error.new(:execution_failure, "fixture checkpoint rejected")}

        [{_, :wait}] ->
          send(context.test, {:checkpoint_waiting, self()})
          receive do: (:commit -> EphemeralStore.store(context.table, run, meta))

        [] ->
          EphemeralStore.store(context.table, run, meta)
      end
    end
  end

  test "notification acknowledgement racing the final provider result does not carry into queued followup" do
    gates = :ets.new(:notification_gate, [:public])
    {pid, _} = start(gates: gates)
    assert {:ok, _} = Conversation.prompt(pid, "first turn")
    assert_receive {:provider, _, provider}, 1_000
    assert {:ok, _} = ordinary(pid)
    assert {:ok, _} = Conversation.follow_up(pid, "second turn")
    :ets.insert(gates, {:next_write, :wait})
    notification = Task.async(fn -> notify(pid) end)
    assert_receive {:checkpoint_waiting, checkpoint}, 1_000
    send(provider, {:events, [done()]})
    send(checkpoint, :commit)
    assert {:ok, %{status: :accepted}} = Task.await(notification)
    assert_receive {:provider, request, provider}, 1_000
    assert count(request, "active notice") == 0
    assert count(request, "ordinary mail") == 1
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "notifications", %{type: :run_completed}}, 1_000
  end

  test "cancellation during a notification checkpoint expires the committed pending entry" do
    gates = :ets.new(:notification_gate, [:public])
    {pid, table} = start(gates: gates)
    assert {:ok, _} = Conversation.prompt(pid, "first turn")
    assert_receive {:provider, _, _}, 1_000
    assert {:ok, _} = ordinary(pid)
    :ets.insert(gates, {:next_write, :wait})
    notification = Task.async(fn -> notify(pid) end)
    assert_receive {:checkpoint_waiting, checkpoint}, 1_000
    assert :ok = Conversation.cancel(pid)
    send(checkpoint, :commit)
    assert {:error, %Error{class: :cancelled}} = Task.await(notification)
    assert_receive {:agent_runtime, "notifications", %{type: :run_cancelled}}, 1_000
    assert {:ok, record} = EphemeralStore.load(table, "notifications")
    assert [%{content: "ordinary mail"}] = record.run.context.conversation.mailbox
  end

  test "a rejected notification checkpoint never reports acceptance or replaces ordinary mail" do
    gates = :ets.new(:notification_gate, [:public])
    {pid, table} = start(gates: gates)
    assert {:ok, _} = Conversation.prompt(pid, "first turn")
    assert_receive {:provider, _, _}, 1_000
    assert {:ok, _} = ordinary(pid)
    :ets.insert(gates, {:next_write, :reject})
    assert {:error, %Error{class: :execution_failure}} = notify(pid)
    assert_receive {:agent_runtime, "notifications", %{type: :storage_failed}}, 1_000
    assert {:ok, record} = EphemeralStore.load(table, "notifications")
    assert [%{content: "ordinary mail"}] = record.run.context.conversation.mailbox
    refute Map.has_key?(record.run.context.conversation, :active_notifications)
  end

  test "same-run queued followup expires missed notifications and retains ordinary mailbox input" do
    {pid, table} = start()
    assert {:ok, _} = Conversation.prompt(pid, "first turn")
    assert_receive {:provider, first, provider}, 1_000
    assert {:ok, %{status: :accepted}} = notify(pid)
    assert {:ok, _} = ordinary(pid)
    assert {:ok, _} = Conversation.follow_up(pid, "second turn")
    assert count(first, "active notice") == 0

    send(provider, {:events, [done()]})
    assert_receive {:provider, second, provider}, 1_000
    assert count(second, "active notice") == 0
    assert count(second, "ordinary mail") == 1
    assert Enum.any?(second.messages, &(&1[:content] == "second turn"))
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "notifications", %{type: :run_completed}}, 1_000
    assert {:ok, record} = EphemeralStore.load(table, "notifications")
    assert record.run.context.conversation.mailbox == []
  end

  for boundary <- [:completed, :failed, :cancelled] do
    test "#{boundary} turn expires only unconsumed notifications in its acknowledged snapshot" do
      boundary = unquote(boundary)
      {pid, table} = start()
      assert {:ok, _} = Conversation.prompt(pid, "first turn")
      assert_receive {:provider, _, provider}, 1_000
      assert {:ok, %{status: :accepted}} = notify(pid)
      assert {:ok, _} = ordinary(pid)

      finish(pid, provider, boundary)

      type =
        %{completed: :run_completed, failed: :run_failed, cancelled: :run_cancelled}[boundary]

      assert_receive {:agent_runtime, "notifications", %{type: ^type}}, 1_000
      assert {:ok, record} = EphemeralStore.load(table, "notifications")
      assert [%{content: "ordinary mail"}] = record.run.context.conversation.mailbox

      assert record.run.context.conversation.active_notifications["notice"].content ==
               "active notice"

      assert :ok = stop_supervised("notifications")

      {replacement, _} =
        start(
          run_id: "notifications-replacement",
          incarnation: 2,
          messages: record.run.context.conversation.messages,
          mailbox: record.run.context.conversation.mailbox
        )

      assert {:ok, _} = Conversation.prompt(replacement, "replacement turn")
      assert_receive {:provider, request, provider}, 1_000
      assert count(request, "active notice") == 0
      assert count(request, "ordinary mail") == 1
      send(provider, {:events, [done()]})

      assert_receive {:agent_runtime, "notifications-replacement", %{type: :run_completed}},
                     1_000
    end
  end

  test "fresh activation rejects legacy pending notifications but keeps consumed history and ordinary mail" do
    old_notice = %{
      role: :user,
      id: "old",
      content: "old active notice",
      collaboration: %{kind: :notification}
    }

    ordinary = %{
      role: :user,
      id: "ordinary",
      content: "ordinary mail",
      collaboration: %{kind: :message}
    }

    {pid, _} = start(mailbox: [old_notice, ordinary], messages: [old_notice])
    assert {:ok, _} = Conversation.prompt(pid, "new activation")
    assert_receive {:provider, request, provider}, 1_000
    assert count(request, "old active notice") == 1
    assert count(request, "ordinary mail") == 1
    send(provider, {:events, [done()]})
    assert_receive {:agent_runtime, "notifications", %{type: :run_completed}}, 1_000
  end

  defp start(opts \\ []) do
    {:ok, table} = EphemeralStore.new(1)
    {gates, opts} = Keyword.pop(opts, :gates)

    options =
      Keyword.merge(
        [
          run_id: "notifications",
          incarnation: 1,
          provider: Provider,
          provider_context: %{test: self()},
          store: if(gates, do: GatedStore, else: EphemeralStore),
          context: if(gates, do: %{table: table, gates: gates, test: self()}, else: table),
          subscriber: self(),
          authority: %{caller: "host", run_id: "notifications", grants: []},
          work: 20,
          run_timeout: 5_000
        ],
        opts
      )

    {start_supervised!({Conversation, options}), table}
  end

  defp notify(pid),
    do:
      Conversation.notify_active(
        pid,
        "active notice",
        %{result_id: "notice", kind: :notification},
        identity()
      )

  defp ordinary(pid),
    do:
      Conversation.queue_only(
        pid,
        "ordinary mail",
        %{result_id: "ordinary", kind: :message},
        identity()
      )

  defp identity, do: %{run_id: "notifications", incarnation: 1, session_binding: nil}
  defp count(request, text), do: Enum.count(request.messages, &(&1[:content] == text))
  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
  defp finish(_pid, provider, :completed), do: send(provider, {:events, [done()]})

  defp finish(_pid, provider, :failed),
    do: send(provider, {:events, [%{type: :response_failed, error: "fixture failure"}]})

  defp finish(pid, _provider, :cancelled), do: assert(:ok == Conversation.cancel(pid))
end
