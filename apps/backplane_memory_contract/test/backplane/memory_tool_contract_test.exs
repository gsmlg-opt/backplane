defmodule Backplane.MemoryToolContractTest do
  use ExUnit.Case, async: true

  alias Backplane.MemoryToolContract

  test "owns the canonical overlap names, schemas, permissions, and discovery metadata" do
    assert MemoryToolContract.canonical_overlap_names() == [
             "memory::facet_query",
             "memory::facet_tag",
             "memory::forget",
             "memory::list",
             "memory::recall",
             "memory::remember",
             "memory::stats"
           ]

    for name <- MemoryToolContract.canonical_overlap_names() do
      assert %{name: ^name, input_schema: schema, meta: %{"backplane" => metadata}} =
               MemoryToolContract.tool!(name)

      assert is_map(schema)

      assert metadata == %{
               "permission" => MemoryToolContract.permission!(name),
               "authority" => "canonical",
               "consistency" => "canonical_or_bounded_stale",
               "availability" => "online_or_offline"
             }
    end

    assert MemoryToolContract.tool!("memory::remember").input_schema["required"] == [
             "content",
             "agent_id"
           ]
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
