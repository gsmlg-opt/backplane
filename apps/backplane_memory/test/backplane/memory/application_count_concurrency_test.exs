defmodule Backplane.Memory.ApplicationCountConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Backplane.Memory.{Audit, Memories}
  alias Backplane.Memory.Memories.{Evidence, Memory, RememberRequest}
  alias Ecto.Adapters.SQL.Sandbox

  @timeout 30_000

  test "concurrent retries of one explicit application increment exactly once" do
    suffix = Ecto.UUID.generate()
    content = "concurrent applied procedure #{suffix}"
    application_id = "application-#{suffix}"
    partition = partition("application-host-#{suffix}")
    cleanup_on_exit(content)

    memory =
      unboxed(fn ->
        {:ok, memory} =
          Memories.remember(content,
            type: "procedural",
            agent_id: "author",
            host_id: partition.host_id,
            client_id: partition.client_id,
            scope: partition.scope,
            namespace: partition.namespace
          )

        memory
      end)

    results =
      1..12
      |> Task.async_stream(
        fn _ ->
          unboxed(fn ->
            Memories.record_application(memory.id, application_id, "executor", partition)
          end)
        end,
        max_concurrency: 12,
        timeout: @timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %{application_count: 1}}}, &1))
    assert Enum.count(results, &match?({:ok, {:ok, %{applied: true}}}, &1)) == 1

    unboxed(fn ->
      assert repo().get!(Memory, memory.id).application_count == 1

      assert Audit.list_for_target(memory.id)
             |> Enum.count(&(&1.operation == "memory.apply")) == 1
    end)
  end

  defp partition(host_id) do
    %{host_id: host_id, client_id: "shared-client", scope: "shared-scope", namespace: "private"}
  end

  defp cleanup_on_exit(content) do
    on_exit(fn ->
      unboxed(fn ->
        ids = repo().all(from(m in Memory, where: m.content == ^content, select: m.id))

        repo().query!("ALTER TABLE memory_audit_log DISABLE TRIGGER USER")

        try do
          for id <- ids do
            repo().query!(
              "DELETE FROM memory_audit_log WHERE target_ids @> jsonb_build_array($1::text)",
              [id]
            )
          end
        after
          repo().query!("ALTER TABLE memory_audit_log ENABLE TRIGGER USER")
        end

        repo().query!("ALTER TABLE bpm_memory_evidence DISABLE TRIGGER USER")
        repo().query!("ALTER TABLE bpm_memory_remember_requests DISABLE TRIGGER USER")

        try do
          repo().delete_all(from(e in Evidence, where: e.memory_id in ^ids))
          repo().delete_all(from(r in RememberRequest, where: r.memory_id in ^ids))
          repo().delete_all(from(m in Memory, where: m.id in ^ids))
        after
          repo().query!("ALTER TABLE bpm_memory_remember_requests ENABLE TRIGGER USER")
          repo().query!("ALTER TABLE bpm_memory_evidence ENABLE TRIGGER USER")
        end
      end)
    end)
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
end
