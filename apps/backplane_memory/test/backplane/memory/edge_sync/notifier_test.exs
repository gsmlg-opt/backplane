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
end
