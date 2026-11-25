defmodule Backplane.ApplicationTest do
  use Backplane.DataCase, async: false

  import ExUnit.CaptureLog

  defmodule FailingSettings do
    def fetch_many(_keys), do: {:error, :database_unavailable}
  end

  alias Backplane.Registry.ToolRegistry
  alias Backplane.Services.{Day, Math, Web}
  alias Backplane.Settings

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

  test "reconciliation ignores the former Skills toggle and leaves management tools unavailable" do
    key = "services.skill.enabled"
    previous_setting = :ets.lookup(:backplane_settings, key)
    previous_rows = :ets.tab2list(:backplane_tools)

    on_exit(fn ->
      :ets.delete(:backplane_settings, key)
      :ets.insert(:backplane_settings, previous_setting)
      :ets.delete_all_objects(:backplane_tools)
      :ets.insert(:backplane_tools, previous_rows)
    end)

    assert :ok = Settings.set(key, true)
    assert :ok = Backplane.Application.reconcile_managed_services()

    for tool <- ToolRegistry.list_all() do
      refute String.starts_with?(tool.name, ["skill::", "hub::", "admin::", "native::"])
    end

    for name <- ~w(skill::search skill::load skill::list skill::download skill::publish
                   hub::discover hub::inspect hub::status hub::refresh hub::cache-status hub::cache-flush
                   admin::list-clients admin::upsert-client) do
      assert :not_found = ToolRegistry.resolve(name)
    end
  end

  test "managed reconciliation fails closed when persisted settings are unavailable" do
    previous_rows = :ets.tab2list(:backplane_tools)

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)

      if previous_rows != [] do
        :ets.insert(:backplane_tools, previous_rows)
      end
    end)

    ToolRegistry.register_managed("test", [
      %{
        name: "test::readiness-sentinel",
        description: "Unrelated managed sentinel",
        input_schema: %{},
        handler: fn args -> {:ok, args} end
      }
    ])

    Enum.each([Day, Web, Math], fn service ->
      ToolRegistry.register_managed(service.prefix(), service.tools())
    end)

    Enum.each(~w(day web math), fn prefix ->
      assert Enum.any?(:ets.tab2list(:backplane_tools), fn {name, _tool} ->
               String.starts_with?(name, prefix <> "::")
             end)
    end)

    assert {:error, {:settings_not_loaded, :database_unavailable}} =
             Backplane.Application.reconcile_managed_services(FailingSettings)

    Enum.each(~w(day web math), fn prefix ->
      refute Enum.any?(:ets.tab2list(:backplane_tools), fn {name, _tool} ->
               String.starts_with?(name, prefix <> "::")
             end)
    end)

    assert %{name: "test::readiness-sentinel", origin: {:managed, "test"}} =
             ToolRegistry.lookup("test::readiness-sentinel")
  end
end
