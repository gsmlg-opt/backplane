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

  test "caches 2020-12 subset validators without changing the function-or-nil API" do
    client = "json-values"

    tools = [
      %{"name" => "list", "outputSchema" => %{"type" => "array", "items" => %{"type" => "integer"}}},
      %{"name" => "scalar", "outputSchema" => %{"type" => "string"}},
      %{"name" => "null", "outputSchema" => %{"type" => "null"}}
    ]

    assert :ok = Cache.put_tool_validators(client, tools, "2026-07-28")

    assert {:ok, [1, 2]} = Cache.get_tool_validator(client, "list").([1, 2])
    assert {:ok, "value"} = Cache.get_tool_validator(client, "scalar").("value")
    assert {:ok, nil} = Cache.get_tool_validator(client, "null").(nil)
    assert is_nil(Cache.get_tool_validator(client, "missing"))

    Cache.cleanup(client)
  end

  test "keeps tools with unsupported schemas usable without a local validator" do
    client = "unsupported-schema"

    tools = [
      %{
        "name" => "referenced",
        "outputSchema" => %{
          "$defs" => %{"value" => %{"type" => "string"}},
          "$ref" => "#/$defs/value"
        }
      }
    ]

    assert :ok = Cache.put_tool_validators(client, tools, "2026-07-28")
    assert is_nil(Cache.get_tool_validator(client, "referenced"))

    Cache.cleanup(client)
  end

  test "retains legacy oneOf validators but omits them for the modern profile" do
    tools = [
      %{
        "name" => "choice",
        "outputSchema" => %{
          "oneOf" => [
            %{"type" => "string"},
            %{"type" => "integer"}
          ]
        }
      }
    ]

    legacy_client = "legacy-one-of"
    assert :ok = Cache.put_tool_validators(legacy_client, tools)

    legacy_validator = Cache.get_tool_validator(legacy_client, "choice")
    assert is_function(legacy_validator, 1)
    assert {:ok, "value"} = legacy_validator.("value")
    assert {:ok, 42} = legacy_validator.(42)
    assert {:error, _} = legacy_validator.(true)

    modern_client = "modern-one-of"
    assert :ok = Cache.put_tool_validators(modern_client, tools, "2026-07-28")
    assert is_nil(Cache.get_tool_validator(modern_client, "choice"))

    Cache.cleanup(legacy_client)
    Cache.cleanup(modern_client)
  end
end
