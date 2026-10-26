defmodule Backplane.MemoryToolContractTest do
  use ExUnit.Case, async: true

  alias Backplane.MemoryToolContract

  for name <- ~w(memory::recall memory::list memory::stats memory::remember memory::forget) do
    test "#{name} exposes an optional shared access UUID selector" do
      schema = MemoryToolContract.tool!(unquote(name)).input_schema

      assert %{"type" => "string", "format" => "uuid", "description" => description} =
               schema["properties"]["memory_access_id"]

      assert description =~ "selector"
      assert description =~ "not a credential"
      assert description =~ "omitted"
      assert description =~ "private default"
      refute "memory_access_id" in Map.get(schema, "required", [])
      refute Map.has_key?(schema["properties"], "authority_version")
    end
  end

  test "shared selectors preserve legacy arguments, requirements, and permissions" do
    legacy = [
      {"memory::recall",
       ~w(query limit scope agent_id session_id host_id tag project token_budget temporal_hints entity_hints include_working channel_weights facets),
       ["query"], false, "memory.read"},
      {"memory::list", ~w(type scope agent_id tag q limit offset), nil, nil, "memory.read"},
      {"memory::stats", [], nil, nil, "memory.read"},
      {"memory::remember",
       ~w(content facets type scope agent_id idempotency_key session_id tags metadata),
       ["content", "agent_id"], false, "memory.write"},
      {"memory::forget", ["id"], ["id"], nil, "memory.write"}
    ]

    for {name, arguments, required, additional_properties, permission} <- legacy do
      tool = MemoryToolContract.tool!(name)
      schema = tool.input_schema

      assert schema["type"] == "object"

      assert schema["properties"] |> Map.delete("memory_access_id") |> Map.keys() |> Enum.sort() ==
               Enum.sort(arguments)

      assert schema["required"] == required
      assert schema["additionalProperties"] == additional_properties
      assert MemoryToolContract.permission!(name) == permission
    end

    assert MemoryToolContract.tool!("memory::list").input_schema["properties"]["offset"] == %{
             "type" => "integer",
             "default" => 0
           }

    assert MemoryToolContract.tool!("memory::remember").input_schema["properties"]["scope"] == %{
             "type" => "string",
             "description" => "Scope key",
             "default" => "global"
           }
  end

  test "facets and device-local tools do not expose shared authority selectors" do
    for name <-
          ~w(memory::facet_query memory::facet_tag) ++ MemoryToolContract.device_local_names() do
      properties = MemoryToolContract.tool!(name).input_schema["properties"]
      refute Map.has_key?(properties, "memory_access_id")
      refute Map.has_key?(properties, "authority_version")
    end
  end

  test "server-only tools remain outside the process-free shared tool schemas" do
    for name <- MemoryToolContract.server_only_names() do
      assert MemoryToolContract.route_class(name) == :server_only
      assert MemoryToolContract.tool(name) == :error
    end
  end

  test "owns the canonical overlap names, schemas, permissions, and discovery metadata" do
    assert MemoryToolContract.canonical_overlap_names() == [
             "memory::facet_query",
             "memory::facet_tag",
             "memory::forget",
             "memory::get",
             "memory::list",
             "memory::recall",
             "memory::remember",
             "memory::stats"
           ]

    for name <- MemoryToolContract.canonical_overlap_names() do
      assert %{name: ^name, input_schema: schema, meta: %{"backplane" => metadata}} =
               MemoryToolContract.tool!(name)

      assert is_map(schema)

      expected = %{
        "permission" => MemoryToolContract.permission!(name),
        "authority" => "canonical",
        "consistency" => "canonical_or_bounded_stale",
        "availability" => "online_or_offline"
      }

      expected =
        if name == "memory::get",
          do: Map.merge(expected, %{"consistency" => "canonical", "availability" => "online"}),
          else: expected

      assert metadata == expected
    end

    assert MemoryToolContract.tool!("memory::remember").input_schema["required"] == [
             "content",
             "agent_id"
           ]
  end

  test "get is an exact canonical read with closed argument and source schemas" do
    tool = MemoryToolContract.tool!("memory::get")
    schema = tool.input_schema
    assert MemoryToolContract.permission!(tool.name) == "memory.read"
    assert MemoryToolContract.route_class(tool.name) == :canonical_overlap
    assert schema["additionalProperties"] == false
    assert schema["required"] == ["id"]
    assert schema["properties"]["id"]["format"] == "uuid"
    assert Enum.sort(Map.keys(schema["properties"])) == ~w(id memory_access_id project source)
    source = schema["properties"]["source"]
    assert source["additionalProperties"] == false
    assert source["minProperties"] == 1
    assert Enum.sort(Map.keys(source["properties"])) == ~w(checkout_root cwd repository_id)
  end

  test "classifies server-only and device-local names without overlap" do
    assert "memory::replay_import" in MemoryToolContract.server_only_names()
    assert "memory::slot_read" in MemoryToolContract.device_local_names()
    assert "memory::facet_tag" in MemoryToolContract.canonical_overlap_names()

    sets = [
      MemoryToolContract.canonical_overlap_names(),
      MemoryToolContract.server_only_names(),
      MemoryToolContract.device_local_names()
    ]

    assert sets
           |> List.flatten()
           |> Enum.uniq()
           |> length() ==
             sets |> List.flatten() |> length()
  end

  test "returns the route class and rejects an unknown memory tool" do
    assert MemoryToolContract.route_class("memory::recall") == :canonical_overlap
    assert MemoryToolContract.route_class("memory::replay_import") == :server_only
    assert MemoryToolContract.route_class("memory::slot_write") == :device_local
    assert MemoryToolContract.route_class("memory::unknown") == :unknown
    assert_raise KeyError, fn -> MemoryToolContract.tool!("memory::unknown") end
  end
end
