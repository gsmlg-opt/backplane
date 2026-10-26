defmodule Backplane.Api.HostAgentMemorySyncTest do
  use ExUnit.Case, async: true

  alias Backplane.Api.HostAgentMemorySync

  test "retired uploader frames and mutable or oversized command batches are rejected" do
    assert {:error, :invalid_request} =
             HostAgentMemorySync.settle_commands(%{}, %{
               "protocol" => "host_memory.v1",
               "items" => []
             })

    assert {:error, :invalid_request} =
             HostAgentMemorySync.settle_commands(%{}, %{
               "protocol" => "memory_commands.v2",
               "items" => [%{}]
             })

    assert {:error, :payload_too_large} =
             HostAgentMemorySync.settle_commands(%{}, %{
               "protocol" => "memory_commands.v2",
               "items" => List.duplicate(%{}, 51)
             })

    assert {:error, :invalid_request} =
             HostAgentMemorySync.settle_commands(%{}, %{
               "protocol" => "memory_commands.v2",
               "items" => [],
               "target" => "default"
             })
  end

  test "an empty canonical command batch has a versioned acknowledgement" do
    assert {:ok, %{protocol: "memory_commands.v2", items: []}} =
             HostAgentMemorySync.settle_commands(%{}, %{
               "protocol" => "memory_commands.v2",
               "items" => []
             })
  end
end
