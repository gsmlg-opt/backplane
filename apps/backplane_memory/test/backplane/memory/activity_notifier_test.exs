defmodule Backplane.Memory.ActivityNotifierTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Backplane.Memory.ActivityNotifier
  alias Backplane.Memory.Projections.{ActivityContribution, ActivityDaily, ActivityStore}
  alias Ecto.Adapters.SQL.Sandbox

  setup_all do
    :ok = Sandbox.mode(repo(), :auto)
    on_exit(fn -> :ok = Sandbox.mode(repo(), :manual) end)
    :ok
  end

  test "broadcasts partition-safe activity invalidation only after projection commit" do
    suffix = System.unique_integer([:positive, :monotonic])
    subject_id = "activity-notifier-#{suffix}"
    partition = partition(suffix)
    :ok = ActivityNotifier.subscribe()
    parent = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          repo().transaction(fn ->
            :ok =
              ActivityStore.replace_subject!(subject_id, "revision-1", partition, [row(suffix)])

            send(parent, {:projected_inside_transaction, self()})

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive {:projected_inside_transaction, transaction_pid}
    refute_receive {:memory_activity_updated, _summary}, 100
    send(transaction_pid, :commit)
    assert {:ok, :ok} = Task.await(task, 5_000)

    assert_receive {:memory_activity_updated, summary}, 1_000

    assert summary == %{
             memory_space_id: partition.memory_space_id,
             host_id: "host-#{suffix}",
             client_id: "client-#{suffix}",
             scope: "scope-#{suffix}",
             namespace: "private",
             date_from: ~D[2026-08-01],
             date_to: ~D[2026-08-01]
           }

    cleanup(subject_id, suffix)
  end

  defp row(suffix) do
    %{
      "date" => "2026-08-01",
      "project" => "backplane",
      "agent_id" => "agent",
      "host_id" => "host-#{suffix}",
      "client_id" => "client-#{suffix}",
      "scope" => "scope-#{suffix}",
      "namespace" => "private",
      "event_type" => "agent.prompt.submitted",
      "event_count" => 1,
      "session_count" => 1,
      "memory_count" => 0,
      "lesson_count" => 0,
      "crystal_count" => 0,
      "recall_count" => 0,
      "action_count" => 0,
      "error_count" => 0
    }
  end

  defp partition(suffix) do
    host_id = "host-#{suffix}"

    %{
      memory_space_id: Backplane.Memory.IngestFixtures.ensure_memory_space!(host_id),
      host_id: host_id,
      client_id: "client-#{suffix}",
      source_client_id: "client-#{suffix}",
      scope: "scope-#{suffix}",
      namespace: "private"
    }
  end

  defp cleanup(subject_id, suffix) do
    unboxed(fn ->
      repo().delete_all(from(c in ActivityContribution, where: c.subject_id == ^subject_id))
      repo().delete_all(from(d in ActivityDaily, where: d.host_id == ^"host-#{suffix}"))
    end)
  end

  defp unboxed(fun) do
    case Sandbox.checkout(repo(), sandbox: false) do
      :ok ->
        try do
          fun.()
        after
          :ok = Sandbox.checkin(repo())
        end

      {:already, :owner} ->
        fun.()
    end
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
