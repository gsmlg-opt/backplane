defmodule Backplane.Services.SkillsTest do
  use Backplane.DataCase, async: false

  alias Backplane.Registry.ToolRegistry
  alias Backplane.Services.Skills
  alias Backplane.Settings
  alias Backplane.Tools.Skill, as: SkillTool

  @setting_key "services.skill.enabled"

  setup do
    previous_enabled = Settings.get(@setting_key)

    previous_rows =
      :backplane_tools
      |> :ets.tab2list()
      |> Enum.filter(fn {name, _tool} -> String.starts_with?(name, "skill::") end)

    on_exit(fn ->
      Settings.set(@setting_key, previous_enabled)
      ToolRegistry.deregister_managed(Skills.prefix())

      if previous_rows != [], do: :ets.insert(:backplane_tools, previous_rows)
    end)

    :ok
  end

  test "exposes the Skill tool definitions with managed handlers" do
    source_tools = SkillTool.tools()
    tools = Skills.tools()

    assert Skills.prefix() == "skill"

    assert Enum.map(tools, &Map.take(&1, [:name, :description, :input_schema])) ==
             Enum.map(source_tools, &Map.take(&1, [:name, :description, :input_schema]))

    for tool <- tools do
      refute Map.has_key?(tool, :module)
      assert is_function(tool.handler, 1)
    end
  end

  test "the enabled skill::list handler delegates to the Skill tool" do
    assert :ok = Settings.set(@setting_key, true)

    handler =
      Skills.tools()
      |> Enum.find(&(&1.name == "skill::list"))
      |> Map.fetch!(:handler)

    assert handler.(%{}) == SkillTool.call(%{"_handler" => "list"})
  end

  test "direct managed handlers reject calls while the service is disabled" do
    assert :ok = Settings.set(@setting_key, false)

    handler =
      Skills.tools()
      |> Enum.find(&(&1.name == "skill::list"))
      |> Map.fetch!(:handler)

    assert {:error, %{code: "service_disabled", message: "Skills service is disabled"}} =
             handler.(%{})
  end

  test "set_enabled/1 persists state and synchronizes the managed skill registry" do
    assert :ok = Skills.set_enabled(false)
    assert Settings.get(@setting_key) == false
    assert :not_found = ToolRegistry.resolve("skill::list")

    assert :ok = Skills.set_enabled(true)
    assert Settings.get(@setting_key) == true
    assert %{origin: {:managed, "skill"}} = ToolRegistry.lookup("skill::list")
    assert {:managed, handler} = ToolRegistry.resolve("skill::list")
    assert is_function(handler, 1)
  end

  test "concurrent opposing toggles serialize persistence and registry synchronization" do
    assert :ok = Skills.set_enabled(false)

    handler_id = "skills-toggle-race-#{System.unique_integer([:positive])}"
    parent = self()
    release_query = make_ref()
    {:ok, gate} = Agent.start_link(fn -> false end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:backplane, :repo, :query],
        fn _event, _measurements, metadata, {test_pid, query_ref, gate} ->
          first_settings_query? =
            metadata[:source] == "system_settings" and
              Agent.get_and_update(gate, fn
                false -> {true, true}
                true -> {false, true}
              end)

          if first_settings_query? do
            send(test_pid, {:settings_query_blocked, self()})

            receive do
              {:release_settings_query, ^query_ref} -> :ok
            end
          end
        end,
        {parent, release_query, gate}
      )

    first_toggle =
      Task.async(fn ->
        Skills.set_enabled(true)
      end)

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if Process.alive?(first_toggle.pid) do
        if settings_pid = Process.whereis(Settings) do
          send(settings_pid, {:release_settings_query, release_query})
        end

        safely_resume(first_toggle.pid)
      end
    end)

    assert_receive {:settings_query_blocked, settings_pid}, 1_000
    assert true = :erlang.suspend_process(first_toggle.pid)
    send(settings_pid, {:release_settings_query, release_query})

    # A system call is a deterministic barrier proving the Settings write and reply completed
    # while the first caller remains suspended before registry synchronization.
    :sys.get_state(Settings)
    assert Settings.get(@setting_key) == true
    assert :not_found = ToolRegistry.resolve("skill::list")

    second_toggle =
      Task.async(fn ->
        send(parent, :opposing_toggle_started)
        Skills.set_enabled(false)
      end)

    on_exit(fn ->
      if Process.alive?(second_toggle.pid), do: safely_resume(second_toggle.pid)
    end)

    assert_receive :opposing_toggle_started, 1_000
    assert Task.yield(second_toggle, 100) == nil

    assert true = :erlang.resume_process(first_toggle.pid)
    assert Task.await(first_toggle, 1_000) == :ok
    assert Task.await(second_toggle, 1_000) == :ok

    assert Settings.get(@setting_key) == false
    assert :not_found = ToolRegistry.resolve("skill::list")
  end

  defp safely_resume(pid) do
    :erlang.resume_process(pid)
  catch
    :error, :badarg -> :ok
  end
end
