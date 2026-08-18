defmodule Backplane.ApplicationTest do
  use Backplane.DataCase, async: false

  import ExUnit.CaptureLog

  defmodule FailingSettings do
    def fetch_many(_keys), do: {:error, :database_unavailable}
  end

  alias Backplane.Registry.{Tool, ToolRegistry}
  alias Backplane.Services.{Day, Math, Skills, Web}
  alias Backplane.Settings

  @service_setting "services.skill.enabled"

  test "prep_stop returns state and does not crash" do
    state = %{some: :state}
    assert Backplane.Application.prep_stop(state) == state
  end

  test "reports a rejected legacy upstream during boot" do
    config = %{
      name: "legacy-skills",
      prefix: " /skill/ ",
      transport: "http",
      url: "http://127.0.0.1:1/mcp",
      headers: %{}
    }

    log =
      capture_log(fn ->
        assert Backplane.Application.start_upstream(config) ==
                 {:error, {:reserved_prefix, "skill"}}
      end)

    assert log =~ "legacy-skills"
    assert log =~ "skill"
    assert log =~ "reserved_prefix"
  end

  test "managed reconciliation honors persisted Skills state and removes stale native rows" do
    previous_setting = :ets.lookup(:backplane_settings, @service_setting)
    previous_rows = :ets.tab2list(:backplane_tools)

    on_exit(fn ->
      :ets.delete(:backplane_settings, @service_setting)

      if previous_setting != [] do
        :ets.insert(:backplane_settings, previous_setting)
      end

      :ets.delete_all_objects(:backplane_tools)

      if previous_rows != [] do
        :ets.insert(:backplane_tools, previous_rows)
      end
    end)

    ToolRegistry.register_native(%Tool{
      name: "test::sentinel",
      description: "Unrelated native sentinel",
      input_schema: %{"type" => "object", "properties" => %{}},
      origin: :native,
      module: __MODULE__,
      handler: nil
    })

    ToolRegistry.register_native(%Tool{
      name: "skill::stale",
      description: "Stale native skill tool",
      input_schema: %{"type" => "object", "properties" => %{}},
      origin: :native,
      module: __MODULE__,
      handler: nil
    })

    assert :ok = Settings.set(@service_setting, false)
    :ets.insert(:backplane_settings, {@service_setting, true})
    send(Backplane.Settings, :seed_and_load)
    Backplane.Application.reconcile_managed_services()

    assert %{name: "test::sentinel", origin: :native} = ToolRegistry.lookup("test::sentinel")

    refute Enum.any?(:ets.tab2list(:backplane_tools), fn {name, _tool} ->
             String.starts_with?(name, "skill::")
           end)

    assert :ok = Settings.set(@service_setting, true)
    :ets.insert(:backplane_settings, {@service_setting, false})
    send(Backplane.Settings, :seed_and_load)
    Backplane.Application.reconcile_managed_services()

    skill_tools =
      :backplane_tools
      |> :ets.tab2list()
      |> Enum.filter(fn {name, _tool} -> String.starts_with?(name, "skill::") end)

    assert length(skill_tools) == 5

    assert Enum.all?(skill_tools, fn {_name, tool} ->
             tool.origin == {:managed, "skill"}
           end)

    assert %{name: "test::sentinel", origin: :native} = ToolRegistry.lookup("test::sentinel")
  end

  test "managed reconciliation fails closed when persisted settings are unavailable" do
    previous_rows = :ets.tab2list(:backplane_tools)

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)

      if previous_rows != [] do
        :ets.insert(:backplane_tools, previous_rows)
      end
    end)

    ToolRegistry.register_native(%Tool{
      name: "test::readiness-sentinel",
      description: "Unrelated native sentinel",
      input_schema: %{"type" => "object", "properties" => %{}},
      origin: :native,
      module: __MODULE__,
      handler: nil
    })

    Enum.each([Day, Web, Math, Skills], fn service ->
      ToolRegistry.register_managed(service.prefix(), service.tools())
    end)

    Enum.each(~w(day web math skill), fn prefix ->
      assert Enum.any?(:ets.tab2list(:backplane_tools), fn {name, _tool} ->
               String.starts_with?(name, prefix <> "::")
             end)
    end)

    assert {:error, {:settings_not_loaded, :database_unavailable}} =
             Backplane.Application.reconcile_managed_services(FailingSettings)

    Enum.each(~w(day web math skill), fn prefix ->
      refute Enum.any?(:ets.tab2list(:backplane_tools), fn {name, _tool} ->
               String.starts_with?(name, prefix <> "::")
             end)
    end)

    assert %{name: "test::readiness-sentinel", origin: :native} =
             ToolRegistry.lookup("test::readiness-sentinel")
  end
end
