defmodule Backplane.HostAgent.ServicesTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{Migrator, Store}
  alias Backplane.HostAgent.Services
  alias Backplane.HostAgent.Services.Day, as: DayService
  alias Backplane.HostAgent.Services.Math, as: MathService
  alias Backplane.HostAgent.Services.Memory, as: MemoryService
  alias ExTurso.Result

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = start_memory!(tmp_dir)

    Application.put_env(:backplane_host_agent, :memory_store, store)
    Application.put_env(:backplane_host_agent, :memory_config, %{bound_scope: "proj_local"})

    on_exit(fn ->
      Application.delete_env(:backplane_host_agent, :local_services)
      Application.delete_env(:backplane_host_agent, :memory_store)
      Application.delete_env(:backplane_host_agent, :memory_config)
    end)

    {:ok, store: store}
  end

  test "resolve returns the registered service and bare tool name" do
    assert {:ok, MemoryService, "recall"} = Services.resolve("memory::recall")
  end

  test "resolve returns day and math local services" do
    assert {:ok, DayService, "now"} = Services.resolve("day::now")
    assert {:ok, MathService, "evaluate"} = Services.resolve("math::evaluate")
  end

  test "resolve returns error for unknown prefix" do
    assert :error = Services.resolve("unknown::tool")
  end

  test "resolve returns error for names without namespace separator" do
    assert :error = Services.resolve("recall")
  end

  test "memory service exposes prefixed tool descriptors" do
    tool_names = Enum.map(MemoryService.tools(), & &1["name"])

    assert "memory::remember" in tool_names
    assert "memory::recall" in tool_names
  end

  test "memory service call uses the context agent_id", %{store: store} do
    assert {:ok, %{"id" => id, "scope" => "proj_local"}} =
             MemoryService.call("remember", %{"content" => "service memory"}, %{
               agent_id: "service-agent"
             })

    assert {:ok, %Result{rows: [%{"agent_id" => "service-agent"}]}} =
             Store.query(store, "SELECT agent_id FROM memories WHERE id = ?", [id])
  end

  test "day service exposes prefixed tool descriptors" do
    tool_names = Enum.map(DayService.tools(), & &1["name"])

    assert tool_names == ["day::now", "day::format", "day::parse", "day::diff"]

    parse_tool = Enum.find(DayService.tools(), &(&1["name"] == "day::parse"))
    assert parse_tool["inputSchema"]["required"] == ["input"]
  end

  test "day service call supports now, parse, format, and diff" do
    assert {:ok, %{iso: iso, timezone: "Etc/UTC", unix: unix}} =
             DayService.call("now", %{}, %{})

    assert is_binary(iso)
    assert is_integer(unix)

    assert {:ok, %{iso: "2026-07-06T00:00:00Z", unix: _}} =
             DayService.call("parse", %{"input" => "2026-07-06T00:00:00Z"}, %{})

    assert {:ok, %{formatted: "2026-07-06"}} =
             DayService.call(
               "format",
               %{"datetime" => "2026-07-06T10:11:12Z", "format" => "YYYY-MM-DD"},
               %{}
             )

    assert {:ok, %{diff: 2, unit: "day"}} =
             DayService.call(
               "diff",
               %{"from" => "2026-07-06T00:00:00Z", "to" => "2026-07-08T00:00:00Z"},
               %{}
             )
  end

  test "day service returns errors for invalid args" do
    assert {:error, _reason} = DayService.call("parse", %{}, %{})
  end

  test "math service exposes prefixed tool descriptors" do
    assert [%{"name" => "math::evaluate", "inputSchema" => schema}] = MathService.tools()
    assert schema["oneOf"] == [%{"required" => ["expr"]}, %{"required" => ["ast"]}]
  end

  test "math service evaluates infix expressions and JSON ASTs" do
    assert {:ok, %{"value" => 14, "ast" => %{"num" => 14}, "latex" => "14", "text" => "14"}} =
             MathService.call("evaluate", %{"expr" => "2 * (3 + 4)"}, %{})

    assert {:ok, %{"value" => 3}} =
             MathService.call(
               "evaluate",
               %{
                 "ast" => %{"op" => "+", "args" => [%{"var" => "x"}, %{"num" => 1}]},
                 "vars" => %{"x" => 2}
               },
               %{}
             )
  end

  test "math service returns errors for invalid args" do
    assert {:error, {:bad_request, :missing_expression}} =
             MathService.call("evaluate", %{}, %{})
  end

  defp start_memory!(tmp_dir) do
    name = :"host_agent_services_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "#{name}.db")

    start_supervised!(
      {Store, database: db_path, name: name, pool_size: 1, busy_timeout_ms: 5_000}
    )

    assert :ok = Migrator.migrate(name)
    name
  end
end
