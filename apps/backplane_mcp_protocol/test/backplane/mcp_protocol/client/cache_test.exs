defmodule Backplane.McpProtocol.Client.CacheTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Client.Cache

  test "isolates validator caches for client processes with the same name" do
    parent = self()
    client_name = "shared-client"
    tools = [%{"name" => "example", "outputSchema" => %{"type" => "object"}}]

    owner =
      Task.async(fn ->
        Cache.put_tool_validators(client_name, tools)
        send(parent, :owner_ready)

        receive do
          {:get_validator, caller} ->
            send(caller, {:validator, Cache.get_tool_validator(client_name, "example")})
        end

        Cache.cleanup(client_name)
      end)

    assert_receive :owner_ready, 1_000

    assert :ok ==
             Task.async(fn ->
               Cache.put_tool_validators(client_name, tools)
               Cache.clear_tool_validators(client_name)
               Cache.cleanup(client_name)
             end)
             |> Task.await()

    send(owner.pid, {:get_validator, self()})
    assert_receive {:validator, validator}, 1_000
    refute is_nil(validator)
    assert :ok == Task.await(owner)
  end
end
