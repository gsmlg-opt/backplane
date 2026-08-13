defmodule Backplane.Memory.CapabilityMatrixTest do
  use ExUnit.Case, async: false

  alias Backplane.Memory.Service

  @matrix_path Path.expand(
                 "../../../../../docs/qualification/memory-v2-capability-matrix.md",
                 __DIR__
               )

  @capabilities ~w(
    Dashboard Graph Memories Timeline Sessions Lessons Actions Crystals Audit Activity Profile
    Replay Config
  )

  setup do
    keys = [
      "memory.tools",
      "memory.pipeline.enabled",
      "memory.replay_enabled",
      "memory.replay_import_enabled"
    ]

    previous = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})

    :ets.insert(:backplane_settings, [
      {"memory.tools", "all"},
      {"memory.pipeline.enabled", true},
      {"memory.replay_enabled", true},
      {"memory.replay_import_enabled", true}
    ])

    on_exit(fn ->
      Enum.each(previous, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)
    end)
  end

  test "maps every product capability across the required API-002 surfaces" do
    matrix = File.read!(@matrix_path)

    assert matrix =~ "| Capability | Operations | Context | REST | MCP or resource | UI | Tests |"

    for capability <- @capabilities do
      assert matrix =~ "| #{capability} |"
    end

    assert matrix =~ "| Recall Inspector |"
    assert matrix =~ "`SessionStart`, `UserPromptSubmit`, `PreCompact`, `Stop`"
    assert matrix =~ "`GET /recall/:recall_run_id/trace`"
    assert matrix =~ "`/memory/recall`, `/memory/recall/:id`"
    assert matrix =~ "memory_recall_inspector_live_test.exs"
  end

  test "every MCP tool named by the matrix is registered" do
    matrix = File.read!(@matrix_path)
    registered = Service.tools() |> Enum.map(& &1.name) |> MapSet.new()

    documented =
      ~r/`(memory::[a-z_]+)`/
      |> Regex.scan(matrix, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    assert MapSet.subset?(documented, registered),
           "unregistered matrix tools: #{inspect(MapSet.difference(documented, registered))}"
  end

  test "documented REST and UI paths remain present in their routers" do
    matrix = File.read!(@matrix_path)
    rest_router = File.read!(Path.expand("../../../lib/backplane/memory/router.ex", __DIR__))

    admin_router =
      File.read!(
        Path.expand("../../../../backplane_admin/lib/backplane/admin/router.ex", __DIR__)
      )

    for path <- [
          "/lessons",
          "/crystals",
          "/activity/summary",
          "/replay/sessions",
          "/recall/:recall_run_id/trace"
        ] do
      assert matrix =~ path
      assert rest_router =~ path
    end

    for path <- [
          "/memory/sessions",
          "/memory/graph",
          "/memory/actions",
          "/memory/activity",
          "/memory/replay",
          "/memory/recall"
        ] do
      assert matrix =~ path
      assert admin_router =~ path
    end
  end
end
