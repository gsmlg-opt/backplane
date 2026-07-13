defmodule Backplane.Memory.ConfigTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Config
  alias Backplane.Settings
  alias Backplane.Settings.Setting

  @settings_table :backplane_settings

  @flags [
    {:pipeline_enabled?, "memory.pipeline.enabled"},
    {:events_enabled?, "memory.events.enabled"},
    {:dual_write?, "memory.events.dual_write"},
    {:window_summaries_enabled?, "memory.window_summaries.enabled"},
    {:session_summary_v2_enabled?, "memory.session_summary_v2.enabled"},
    {:fact_extraction_v2_enabled?, "memory.fact_extraction_v2.enabled"},
    {:procedure_extraction_v2_enabled?, "memory.procedure_extraction_v2.enabled"},
    {:recall_v2_enabled?, "memory.recall_v2.enabled"}
  ]

  @children tl(@flags)
  @independent_children Enum.drop(@flags, 3)

  setup do
    snapshot =
      Map.new(@flags, fn {_accessor, key} ->
        {key, :ets.lookup(@settings_table, key)}
      end)

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(@settings_table, key)

        if rows != [] do
          :ets.insert(@settings_table, rows)
        end
      end)
    end)

    Enum.each(@flags, fn {_accessor, key} -> :ets.delete(@settings_table, key) end)

    :ok
  end

  test "all rollout settings are typed disabled defaults with descriptions" do
    for {_accessor, key} <- @flags do
      assert Settings.get(key) == false

      assert %Setting{
               value: %{"v" => false},
               value_type: "boolean",
               description: description
             } = repo().get!(Setting, key)

      assert is_binary(description)
      assert String.trim(description) != ""
    end
  end

  test "all accessors are false by default" do
    for {accessor, _key} <- @flags do
      refute apply(Config, accessor, [])
    end
  end

  test "the pipeline master gate requires boolean true and disables every child" do
    Enum.each(@children, fn {_accessor, key} -> put_setting(key, true) end)

    for value <- [nil, false, "true", 1, %{}] do
      put_setting("memory.pipeline.enabled", value)

      refute Config.pipeline_enabled?()

      for {accessor, _key} <- @children do
        refute apply(Config, accessor, [])
      end
    end

    put_setting("memory.pipeline.enabled", true)
    assert Config.pipeline_enabled?()
  end

  test "events require their flag and dual-write requires both event flags" do
    put_setting("memory.pipeline.enabled", true)

    put_setting("memory.events.enabled", "true")
    refute Config.events_enabled?()

    put_setting("memory.events.enabled", true)
    assert Config.events_enabled?()
    refute Config.dual_write?()

    put_setting("memory.events.dual_write", "true")
    refute Config.dual_write?()

    put_setting("memory.events.dual_write", true)
    assert Config.dual_write?()

    put_setting("memory.events.enabled", false)
    refute Config.events_enabled?()
    refute Config.dual_write?()
  end

  test "non-event children depend only on the master and their own strict boolean flag" do
    put_setting("memory.pipeline.enabled", true)

    for {accessor, key} <- @independent_children do
      Enum.each(@independent_children, fn {_other_accessor, other_key} ->
        :ets.delete(@settings_table, other_key)
      end)

      put_setting(key, "true")
      refute apply(Config, accessor, [])

      put_setting(key, true)
      assert apply(Config, accessor, [])

      for {other_accessor, other_key} <- @independent_children, other_key != key do
        refute apply(Config, other_accessor, [])
      end

      refute Config.events_enabled?()
      refute Config.dual_write?()
    end
  end

  defp put_setting(key, nil), do: :ets.delete(@settings_table, key)
  defp put_setting(key, value), do: :ets.insert(@settings_table, {key, value})
end
