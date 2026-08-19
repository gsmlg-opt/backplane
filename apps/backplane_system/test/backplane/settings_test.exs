defmodule Backplane.SettingsTest do
  use BackplaneSystem.DataCase, async: false

  defmodule FailingRepo do
    def all(_query), do: raise("database unavailable")
  end

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Settings
  alias Backplane.Settings.Setting

  describe "list_definitions/0" do
    test "does not expose internal service toggles as settings options" do
      assert Settings.list_definitions() == []
    end
  end

  describe "defaults" do
    test "smart auto model has no default target models" do
      key = "llm.auto_models.smart.targets"

      Repo.delete_all(from(s in Setting, where: s.key == ^key))
      :ets.delete(:backplane_settings, key)

      assert Settings.get(key) == []
    end
  end

  describe "serialized settings operations" do
    test "fetch_many/1 returns the requested values after the initial load succeeds" do
      assert {:ok, values} =
               Settings.fetch_many([
                 "services.day.enabled",
                 "services.web.enabled",
                 "services.skill.enabled"
               ])

      assert values == %{
               "services.day.enabled" => Settings.get("services.day.enabled"),
               "services.web.enabled" => Settings.get("services.web.enabled"),
               "services.skill.enabled" => Settings.get("services.skill.enabled")
             }
    end

    test "load_all/1 returns the repository exception when loading fails" do
      assert {:error, %RuntimeError{message: "database unavailable"}} =
               Settings.load_all(FailingRepo)
    end

    test "fetch_many/1 retries a failed load and restores ready status" do
      previous_state = :sys.get_state(Settings)

      on_exit(fn ->
        :sys.replace_state(Settings, fn _state -> previous_state end)
      end)

      :sys.replace_state(Settings, fn state ->
        Map.put(state, :load_status, {:error, :database_unavailable})
      end)

      assert {:ok, %{"services.skill.enabled" => enabled}} =
               Settings.fetch_many(["services.skill.enabled"])

      assert is_boolean(enabled)
      assert %{load_status: :ok} = :sys.get_state(Settings)
    end

    test "get_many/1 returns the requested values from one snapshot" do
      first = unique_key("snapshot-first")
      second = unique_key("snapshot-second")
      on_exit(fn -> delete_cached([first, second]) end)

      assert :ok = Settings.set(first, "one")
      assert :ok = Settings.set(second, %{"two" => 2})

      assert Settings.get_many([first, second, "missing-setting"]) == %{
               first => "one",
               second => %{"two" => 2},
               "missing-setting" => nil
             }
    end

    test "set_if/3 persists and broadcasts exactly once when expectations match" do
      target = unique_key("conditional-target")
      dependency = unique_key("conditional-dependency")
      on_exit(fn -> delete_cached([target, dependency]) end)

      assert :ok = Settings.set(target, false)
      assert :ok = Settings.set(dependency, :ready)
      assert :ok = Settings.subscribe()
      flush_setting_messages()

      assert :ok = Settings.set_if(target, true, [{dependency, :ready}])
      assert Settings.get(target) == true
      assert Repo.get!(Setting, target).value == %{"v" => true}
      assert_receive {:setting_changed, ^target, true}
      refute_receive {:setting_changed, ^target, true}
    end

    test "set_if/3 neither writes nor broadcasts when an expectation fails" do
      target = unique_key("condition-failure-target")
      dependency = unique_key("condition-failure-dependency")
      on_exit(fn -> delete_cached([target, dependency]) end)

      assert :ok = Settings.set(target, false)
      assert :ok = Settings.set(dependency, :blocked)
      assert :ok = Settings.subscribe()
      flush_setting_messages()

      assert {:error, {:condition_failed, ^dependency}} =
               Settings.set_if(target, true, [{dependency, :ready}])

      assert Settings.get(target) == false
      assert Repo.get!(Setting, target).value == %{"v" => false}
      refute_receive {:setting_changed, ^target, true}
    end

    test "set_if/3 treats the current target value as a no-op without broadcasting" do
      target = unique_key("conditional-noop-target")
      dependency = unique_key("conditional-noop-dependency")
      on_exit(fn -> delete_cached([target, dependency]) end)

      assert :ok = Settings.set(target, true)
      assert :ok = Settings.set(dependency, :blocked)
      assert :ok = Settings.subscribe()
      flush_setting_messages()

      assert :ok = Settings.set_if(target, true, [{dependency, :ready}])
      assert Settings.get(target) == true
      refute_receive {:setting_changed, ^target, true}
    end
  end

  defp unique_key(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp delete_cached(keys) do
    Enum.each(keys, &:ets.delete(:backplane_settings, &1))
  end

  defp flush_setting_messages do
    receive do
      {:setting_changed, _key, _value} -> flush_setting_messages()
    after
      0 -> :ok
    end
  end
end
