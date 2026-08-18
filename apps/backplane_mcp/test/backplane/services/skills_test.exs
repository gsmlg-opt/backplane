defmodule Backplane.Services.SkillsTest do
  use Backplane.DataCase, async: false

  alias Backplane.Registry.ToolRegistry
  alias Backplane.Services.Skills
  alias Backplane.Settings
  alias Backplane.Tools.Skill, as: SkillTool

  @setting_key "services.skill.enabled"

  setup do
    previous_enabled = Settings.get(@setting_key)

    previous_tools =
      SkillTool.tools()
      |> Enum.map(&ToolRegistry.lookup(&1.name))
      |> Enum.reject(&is_nil/1)

    on_exit(fn ->
      Settings.set(@setting_key, previous_enabled)
      ToolRegistry.deregister_managed(Skills.prefix())

      Enum.each(previous_tools, fn tool ->
        ToolRegistry.register_native(tool)
      end)
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
end
