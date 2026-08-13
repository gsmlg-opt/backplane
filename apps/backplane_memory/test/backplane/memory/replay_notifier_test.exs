defmodule Backplane.Memory.ReplayNotifierTest do
  use ExUnit.Case, async: false

  alias Backplane.Memory.ReplayNotifier
  alias Ecto.Adapters.SQL.Sandbox

  setup_all do
    started? = application_started?(:backplane_memory)
    :ok = Sandbox.mode(repo(), :auto)
    {:ok, _started} = Application.ensure_all_started(:backplane_memory)

    on_exit(fn ->
      if not started?, do: Application.stop(:backplane_memory)
      :ok = Sandbox.mode(repo(), :manual)
    end)

    :ok
  end

  test "broadcasts a content-free invalidation only after replay projection commit" do
    suffix = Ecto.UUID.generate()
    session = "replay-notifier-#{suffix}"
    input_revision = String.duplicate("a", 64)
    :ok = ReplayNotifier.subscribe()
    parent = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          repo().transaction(fn ->
            :ok =
              ReplayNotifier.enqueue(repo(), %{
                session_id: session,
                input_revision: input_revision
              })

            send(parent, {:enqueued_inside_transaction, self()})

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive {:enqueued_inside_transaction, transaction_pid}
    refute_receive {:memory_replay_updated, _summary}, 100
    send(transaction_pid, :commit)
    assert {:ok, :ok} = Task.await(task, 5_000)

    assert_receive {:memory_replay_updated, summary}, 5_000
    assert summary["session_id"] == session
    assert summary["input_revision"] == input_revision
    refute Map.has_key?(summary, "detail")
  end

  defp unboxed(fun) do
    :ok = Sandbox.checkout(repo(), sandbox: false)

    try do
      fun.()
    after
      :ok = Sandbox.checkin(repo())
    end
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  defp application_started?(application) do
    Enum.any?(Application.started_applications(), fn {started, _description, _version} ->
      started == application
    end)
  end
end
