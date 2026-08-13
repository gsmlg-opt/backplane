defmodule Backplane.Memory.GeneratedSkillsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.GeneratedSkills
  alias Backplane.Skills
  alias Backplane.Settings

  @settings ~w(services.memory.enabled memory.tools memory.pipeline.enabled memory.replay_enabled memory.replay_import_enabled)

  setup do
    snapshot = Map.new(@settings, &{&1, :ets.lookup(:backplane_settings, &1)})

    put_settings(%{
      "services.memory.enabled" => true,
      "memory.tools" => "all",
      "memory.pipeline.enabled" => true,
      "memory.replay_enabled" => true,
      "memory.replay_import_enabled" => true
    })

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)
    end)

    :ok
  end

  test "reconciles a canonical lessons reference skill from live tool contracts" do
    assert :ok = GeneratedSkills.reconcile()
    assert {:ok, skill} = Skills.get_by_slug("lessons")

    assert skill.id == "generated/memory-lessons"
    assert skill.source_kind == "generated"
    assert skill.tags == ["memory", "lessons"]
    assert skill.meta["path"] == "/lessons"

    for tool <-
          ~w(memory::lesson_save memory::lesson_recall memory::lesson_strengthen memory::lesson_promote memory::lesson_archive) do
      assert tool in skill.meta["tools"]
      assert skill.content =~ tool
    end

    assert is_map(skill.meta["tool_schemas"])
    assert map_size(skill.meta["tool_schemas"]) == 5
  end

  test "reconciliation is idempotent" do
    assert :ok = GeneratedSkills.reconcile()
    assert {:ok, first} = Skills.get_by_slug("lessons")
    assert :ok = GeneratedSkills.reconcile()
    assert {:ok, second} = Skills.get_by_slug("lessons")
    assert second.id == first.id
    assert second.content_hash == first.content_hash
  end

  test "reconciles the activity reference skill from live bounded contracts" do
    assert :ok = GeneratedSkills.reconcile()
    assert {:ok, skill} = Skills.get_by_slug("activity")

    assert skill.id == "generated/memory-activity"
    assert skill.meta["path"] == "/activity"

    for tool <-
          ~w(memory::activity_summary memory::replay_sessions memory::replay_load memory::replay_import) do
      assert tool in skill.meta["tools"]
      assert skill.content =~ tool
      assert skill.meta["tool_schemas"][tool]["additionalProperties"] == false
    end

    refute skill.content =~ "approved_roots"
    refute skill.content =~ ~s("path")
  end

  test "reconciles recap and handoff so the packaged Memory inventory is exactly eight" do
    assert :ok = GeneratedSkills.reconcile()

    generated =
      Skills.list()
      |> Enum.filter(&(&1.source_kind == "generated" and &1.category == "memory"))
      |> Enum.map(& &1.slug)
      |> Enum.sort()

    packaged =
      :backplane_memory
      |> :code.priv_dir()
      |> Path.join("skills/*.json")
      |> Path.wildcard()
      |> Enum.map(fn path -> path |> File.read!() |> Jason.decode!() |> Map.fetch!("name") end)
      |> Enum.sort()

    assert generated == ~w(activity handoff lessons recap)
    assert packaged == ~w(forget recall remember session-history)

    assert Enum.sort(generated ++ packaged) ==
             ~w(activity forget handoff lessons recall recap remember session-history)

    for {slug, path, tools} <- [
          {"recap", "/recap",
           ~w(memory::activity_summary memory::recall_explain memory::replay_load memory::replay_sessions)},
          {"handoff", "/handoff",
           ~w(memory::frontier memory::lesson_recall memory::sessions memory::timeline)}
        ] do
      assert {:ok, skill} = Skills.get_by_slug(slug)
      assert skill.meta["path"] == path
      assert Enum.sort(skill.meta["tools"]) == tools
      assert Map.keys(skill.meta["tool_schemas"]) |> Enum.sort() == tools
    end
  end

  test "generated metadata follows the live core tool inventory" do
    put_settings(%{"memory.tools" => "core"})

    assert :ok = GeneratedSkills.reconcile()

    assert skill_tools("lessons") == ~w(memory::lesson_recall memory::lesson_save)

    assert skill_tools("activity") ==
             ~w(memory::activity_summary memory::replay_load memory::replay_sessions)

    assert skill_tools("recap") ==
             ~w(memory::activity_summary memory::recall_explain memory::replay_load memory::replay_sessions)

    assert skill_tools("handoff") ==
             ~w(memory::frontier memory::lesson_recall memory::sessions memory::timeline)
  end

  test "generated activity metadata follows replay-import feature visibility" do
    put_settings(%{"memory.tools" => "all", "memory.replay_import_enabled" => false})
    assert :ok = GeneratedSkills.reconcile()

    assert skill_tools("activity") ==
             ~w(memory::activity_summary memory::replay_load memory::replay_sessions)

    put_settings(%{"memory.replay_import_enabled" => true})
    assert :ok = GeneratedSkills.reconcile()

    assert skill_tools("activity") ==
             ~w(memory::activity_summary memory::replay_import memory::replay_load memory::replay_sessions)
  end

  test "disabled Memory removes generated skills from the advertised inventory" do
    assert :ok = GeneratedSkills.reconcile()
    assert Enum.any?(Skills.list(), &(&1.id == "generated/memory-lessons"))

    put_settings(%{"services.memory.enabled" => false})
    assert :ok = GeneratedSkills.reconcile()

    refute Enum.any?(Skills.list(), &String.starts_with?(&1.id, "generated/memory-"))
    assert {:ok, disabled} = Skills.get_by_slug("lessons")
    refute disabled.enabled
  end

  test "relevant runtime setting changes reconcile the advertised inventory" do
    assert is_pid(Process.whereis(GeneratedSkills))
    assert :ok = GeneratedSkills.reconcile()

    assert :ok = Settings.set("memory.tools", "core")

    assert_eventually(fn ->
      skill_tools("lessons") == ~w(memory::lesson_recall memory::lesson_save)
    end)

    assert :ok = Settings.set("services.memory.enabled", false)

    assert_eventually(fn ->
      not Enum.any?(Skills.list(), &String.starts_with?(&1.id, "generated/memory-"))
    end)
  end

  defp skill_tools(slug) do
    assert {:ok, skill} = Skills.get_by_slug(slug)
    Enum.sort(skill.meta["tools"])
  end

  defp put_settings(settings) do
    Enum.each(settings, fn {key, value} -> :ets.insert(:backplane_settings, {key, value}) end)
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
