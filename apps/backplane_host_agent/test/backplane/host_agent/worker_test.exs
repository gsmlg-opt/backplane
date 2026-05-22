defmodule Backplane.HostAgent.WorkerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Worker

  test "status returns last sync state" do
    {:ok, pid} = Worker.start_link(name: nil)

    assert %{last_sync: nil, last_error: nil} = GenServer.call(pid, :status)
  end
end
