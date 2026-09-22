defmodule Backplane.Api.MemoryToolSchemaParityTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.MCP.Dispatch
  alias Backplane.Memory.Service
  alias Backplane.MemoryToolContract
  alias Backplane.Registry.ToolRegistry

  setup do
    snapshot = :ets.tab2list(:backplane_tools)

    settings =
      preserve_settings(
        ~w(memory.tools memory.pipeline.enabled memory.replay_enabled memory.replay_import_enabled)
      )

    :ets.delete_all_objects(:backplane_tools)

    for {key, value} <- [
          {"memory.tools", "all"},
          {"memory.pipeline.enabled", true},
          {"memory.replay_enabled", true},
          {"memory.replay_import_enabled", true}
        ] do
      :ets.insert(:backplane_settings, {key, value})
    end

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)
      :ets.insert(:backplane_tools, snapshot)
      restore_settings(settings)
    end)

    :ok = ToolRegistry.register_managed("memory", Service.tools())
    :ok
  end

  test "modern direct discovery preserves the memory tool contract metadata and server-only names" do
    assert {:ok, %{"tools" => tools}} =
             Dispatch.execute("tools/list", %{}, %{
               protocol_version: "2026-07-28",
               scopes: ["*"],
               auth: %{},
               client: nil
             })

    direct = Map.new(tools, &{&1["name"], &1})

    for name <- MemoryToolContract.canonical_overlap_names() do
      contract = MemoryToolContract.tool!(name)

      assert %{
               "name" => ^name,
               "description" => description,
               "inputSchema" => input_schema,
               "_meta" => meta
             } = Map.fetch!(direct, name)

      assert description == contract.description
      assert input_schema == contract.input_schema
      assert meta == contract.meta
    end

    for name <- MemoryToolContract.server_only_names() do
      {:ok, meta} = MemoryToolContract.metadata(name)
      assert %{"name" => ^name, "_meta" => ^meta} = Map.fetch!(direct, name)
    end

    for name <- MemoryToolContract.device_local_names() do
      refute Map.has_key?(direct, name)
    end
  end

  defp preserve_settings(keys), do: Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})

  defp restore_settings(settings) do
    Enum.each(settings, fn
      {key, []} -> :ets.delete(:backplane_settings, key)
      {_key, rows} -> :ets.insert(:backplane_settings, rows)
    end)
  end
end
