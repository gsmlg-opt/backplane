defmodule Backplane.Memory.EdgeSync.NotifierTest do
  use ExUnit.Case, async: false
  alias Backplane.Memory.EdgeSync.Notifier

  test "listener forwards only validated content-free hints" do
    :ok = Notifier.subscribe()
    pid = Process.whereis(Notifier)
    %{listen_ref: ref, connection: connection} = :sys.get_state(pid)

    hint = %{
      "memory_space_id" => Ecto.UUID.generate(),
      "scope" => "a",
      "namespace" => "private",
      "current_revision" => 4
    }

    send(
      pid,
      {:notification, connection, ref, "bpm_memory_edge_available",
       Jason.encode!(Map.put(hint, "content", "secret"))}
    )

    refute_receive {:memory_available, _}, 50
    send(pid, {:notification, connection, ref, "bpm_memory_edge_available", Jason.encode!(hint)})
    assert_receive {:memory_available, ^hint}
    send(pid, {:notification, connection, ref, "bpm_memory_edge_available", "bad json"})
    send(pid, :unknown)
    assert Process.alive?(pid)
  end

  test "access bridge validates exact content-free shape and PostgreSQL emits only committed changes" do
    host = Ecto.UUID.generate()
    :ok = Phoenix.PubSub.subscribe(Backplane.PubSub, "host_agent:" <> host)
    pid = Process.whereis(Notifier)
    %{access_listen_ref: ref, connection: connection} = :sys.get_state(pid)

    hint = %{
      "host_id" => host,
      "access_id" => Ecto.UUID.generate(),
      "authority_version" => 2,
      "status" => "revoked"
    }

    for invalid <- [
          Map.put(hint, "content", "protected"),
          %{hint | "status" => "other"},
          %{hint | "authority_version" => 0},
          %{hint | "host_id" => "invalid"}
        ] do
      send(
        pid,
        {:notification, connection, ref, "bpm_memory_access_changed", Jason.encode!(invalid)}
      )
    end

    refute_receive {:memory_access_changed, _}, 50
    wire = Map.delete(hint, "host_id")
    send(pid, {:notification, connection, ref, "bpm_memory_access_changed", Jason.encode!(hint)})
    assert_receive {:memory_access_changed, ^wire}

    {:ok, repo} =
      Backplane.Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 1)

    previous = Backplane.Repo.put_dynamic_repo(repo)

    try do
      assert {:error, :fixture_rollback} =
               Backplane.Repo.transaction(fn ->
                 Backplane.Repo.query!("SELECT pg_notify('bpm_memory_access_changed',$1)", [
                   Jason.encode!(hint)
                 ])

                 refute_receive {:memory_access_changed, _}, 50
                 Backplane.Repo.rollback(:fixture_rollback)
               end)

      refute_receive {:memory_access_changed, _}, 50

      assert {:ok, _} =
               Backplane.Repo.transaction(fn ->
                 Backplane.Repo.query!("SELECT pg_notify('bpm_memory_access_changed',$1)", [
                   Jason.encode!(hint)
                 ])

                 refute_receive {:memory_access_changed, _}, 50
               end)

      assert_receive {:memory_access_changed, ^wire}, 2_000
    after
      Backplane.Repo.put_dynamic_repo(previous)
      Supervisor.stop(repo)
    end
  end
end
