defmodule Backplane.SettingsTest do
  use BackplaneSystem.DataCase, async: false

  defmodule FailingRepo do
    def all(_query), do: raise("database unavailable")
  end

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Settings
  alias Backplane.Settings.Setting

  @automatic_memory_flags ~w(memory.pipeline.enabled memory.host_sync.enabled memory.recall.enabled memory.session_summary.enabled memory.fact_extraction.enabled)

  describe "list_definitions/0" do
    test "does not expose internal service toggles as settings options" do
      assert Settings.list_definitions() == []
    end
  end

  describe "defaults" do
    test "automatic memory processing is enabled without saved settings and seeded enabled" do
      preserve_cached(@automatic_memory_flags)

      Repo.delete_all(from(setting in Setting, where: setting.key in ^@automatic_memory_flags))
      delete_cached(@automatic_memory_flags)

      for key <- @automatic_memory_flags do
        assert Settings.default_value(key) == true
        assert Settings.get(key) == true
      end

      send(Settings, :seed_and_load)
      :sys.get_state(Settings)

      for key <- @automatic_memory_flags do
        assert %Setting{value: %{"v" => true}, value_type: "boolean"} = Repo.get!(Setting, key)
        assert Settings.get(key) == true
      end
    end

    test "saved automatic memory disablement survives reseeding and cache reload" do
      preserve_cached(@automatic_memory_flags)

      for key <- @automatic_memory_flags, do: assert(:ok = Settings.set(key, false))
      delete_cached(@automatic_memory_flags)

      send(Settings, :seed_and_load)
      :sys.get_state(Settings)

      for key <- @automatic_memory_flags do
        assert %Setting{value: %{"v" => false}, value_type: "boolean"} = Repo.get!(Setting, key)
        assert Settings.get(key) == false
      end
    end

    test "API usage fetching is enabled without a saved setting" do
      key = "monitor.api_usage.enabled"
      previous = :ets.lookup(:backplane_settings, key)

      on_exit(fn ->
        if previous == [],
          do: :ets.delete(:backplane_settings, key),
          else: :ets.insert(:backplane_settings, previous)
      end)

      Repo.delete_all(from(setting in Setting, where: setting.key == ^key))
      :ets.delete(:backplane_settings, key)
      assert Settings.get(key) == true
    end

    test "host delivery uses one enabled setting and retains its item bound" do
      for {key, expected} <- [
            {"memory.host_sync.enabled", true},
            {"memory.host_sync_max_item_bytes", 262_144}
          ] do
        Repo.delete_all(from(s in Setting, where: s.key == ^key))
        :ets.delete(:backplane_settings, key)
        assert Settings.get(key) == expected
      end

      assert Settings.default_value("memory.host_sync_v1.enabled") == nil
      assert Settings.default_value("memory.host_sync_v2.enabled") == nil
    end

    test "retired memory runtime selectors have no defaults" do
      for key <-
            ~w(memory.host_sync_v1.enabled memory.events.enabled memory.events.dual_write memory.recall_v2.enabled) do
        Repo.delete_all(from(s in Setting, where: s.key == ^key))
        :ets.delete(:backplane_settings, key)
        assert Settings.get(key) == nil
      end
    end

    test "smart auto model has no default target models" do
      key = "llm.auto_models.smart.targets"

      Repo.delete_all(from(s in Setting, where: s.key == ^key))
      :ets.delete(:backplane_settings, key)

      assert Settings.get(key) == []
    end
  end

  describe "serialized settings operations" do
    test "embedding selection commits and rolls back on an idle real connection pool" do
      model_key = "memory.embed_model"
      cutoff_key = "memory.recall_relevance_vector_min"
      preserve_cached([model_key, cutoff_key])
      delete_cached([model_key, cutoff_key])
      assert :ok = Settings.subscribe()
      flush_setting_messages()

      with_real_settings_repo(fn schema ->
        refute Repo.in_transaction?()
        assert :ok = settings_callback({:set, model_key, "real-pool/embed-a"})
        assert Repo.get!(Setting, model_key).value == %{"v" => "real-pool/embed-a"}
        assert Repo.get!(Setting, cutoff_key).value == %{"v" => 1.0}
        assert_receive {:setting_changed, ^model_key, "real-pool/embed-a"}
        assert_receive {:setting_changed, ^cutoff_key, 1.0}

        assert :ok = settings_callback({:set, cutoff_key, 0.65})
        assert :ok = settings_callback({:set, model_key, " real-pool/embed-a "})
        assert Settings.get(cutoff_key) == 0.65
        assert Repo.get!(Setting, cutoff_key).value == %{"v" => 0.65}

        assert :ok =
                 settings_callback(
                   {:set_if, model_key, "real-pool/embed-b", [{model_key, " real-pool/embed-a "}]}
                 )

        assert Settings.get(model_key) == "real-pool/embed-b"
        assert Settings.get(cutoff_key) == 1.0
        assert Repo.get!(Setting, cutoff_key).value == %{"v" => 1.0}
        assert :ok = settings_callback({:set, cutoff_key, 0.7})
        flush_setting_messages()

        Repo.query!("""
        CREATE FUNCTION "#{schema}".reject_embedding_cutoff() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.key = 'memory.recall_relevance_vector_min' THEN
            RAISE EXCEPTION 'fixture cutoff persistence refused';
          END IF;
          RETURN NEW;
        END $$
        """)

        Repo.query!("""
        CREATE TRIGGER reject_embedding_cutoff BEFORE INSERT OR UPDATE ON system_settings
        FOR EACH ROW EXECUTE FUNCTION "#{schema}".reject_embedding_cutoff()
        """)

        for request <- [
              {:set, model_key, "real-pool/embed-rejected"},
              {:set_if, model_key, "real-pool/embed-rejected", [{model_key, "real-pool/embed-b"}]}
            ] do
          assert {:error, %Postgrex.Error{}} = settings_callback(request)
          assert Settings.get(model_key) == "real-pool/embed-b"
          assert Settings.get(cutoff_key) == 0.7
          assert Repo.get!(Setting, model_key).value == %{"v" => "real-pool/embed-b"}
          assert Repo.get!(Setting, cutoff_key).value == %{"v" => 0.7}
          refute_receive {:setting_changed, ^model_key, _}
          refute_receive {:setting_changed, ^cutoff_key, _}
          refute Repo.in_transaction?()
        end
      end)
    end

    test "one embedding selection seeds a missing float cutoff and invalidates it on actual model changes" do
      model_key = "memory.embed_model"
      cutoff_key = "memory.recall_relevance_vector_min"
      keys = [model_key, cutoff_key]
      preserve_cached(keys)
      Repo.delete_all(from(setting in Setting, where: setting.key in ^keys))
      delete_cached(keys)

      assert Settings.default_value("memory.recall_relevance_vector_model") == nil
      assert :ok = Settings.set(model_key, "provider/embed-a")
      assert Settings.get(cutoff_key) == 1.0
      assert %Setting{value: %{"v" => 1.0}, value_type: "float"} = Repo.get!(Setting, cutoff_key)

      assert :ok = Settings.set(cutoff_key, 0.65)
      assert :ok = Settings.set(model_key, " provider/embed-a ")
      assert Settings.get(cutoff_key) == 0.65
      assert Repo.get!(Setting, cutoff_key).value == %{"v" => 0.65}

      assert :ok =
               Settings.set_if(model_key, "provider/embed-b", [{model_key, " provider/embed-a "}])

      assert Settings.get(cutoff_key) == 1.0
      assert Repo.get!(Setting, model_key).value == %{"v" => "provider/embed-b"}
      assert Repo.get!(Setting, cutoff_key).value == %{"v" => 1.0}

      assert :ok = Settings.set(cutoff_key, 0.7)
      assert :ok = Settings.set_if(model_key, " provider/embed-b ", [])
      assert Settings.get(cutoff_key) == 0.7

      assert {:error, {:condition_failed, ^model_key}} =
               Settings.set_if(model_key, "provider/embed-c", [{model_key, "wrong-model"}])

      assert Settings.get(cutoff_key) == 0.7

      refute Setting.changeset(%Setting{}, %{
               key: "invalid-setting-type",
               value: %{"v" => 0.5},
               value_type: "unsupported"
             }).valid?
    end

    test "embedding selection and cutoff roll back together without cache updates or broadcasts" do
      model_key = "memory.embed_model"
      cutoff_key = "memory.recall_relevance_vector_min"
      preserve_cached([model_key, cutoff_key])
      assert :ok = Settings.set(model_key, "provider/embed-before")
      assert :ok = Settings.set(cutoff_key, 0.65)
      assert :ok = Settings.subscribe()
      flush_setting_messages()

      Repo.query!("""
      CREATE FUNCTION pg_temp.reject_embedding_cutoff() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.key = 'memory.recall_relevance_vector_min' THEN
          RAISE EXCEPTION 'fixture cutoff persistence refused';
        END IF;
        RETURN NEW;
      END $$
      """)

      Repo.query!("""
      CREATE TRIGGER reject_embedding_cutoff BEFORE INSERT OR UPDATE ON system_settings
      FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_embedding_cutoff()
      """)

      for update <- [
            fn -> Settings.set(model_key, "provider/embed-after") end,
            fn ->
              Settings.set_if(model_key, "provider/embed-after", [
                {model_key, "provider/embed-before"}
              ])
            end
          ] do
        assert {:error, %Postgrex.Error{}} = update.()

        assert Settings.get_many([model_key, cutoff_key]) == %{
                 model_key => "provider/embed-before",
                 cutoff_key => 0.65
               }

        assert Repo.get!(Setting, model_key).value == %{"v" => "provider/embed-before"}
        assert Repo.get!(Setting, cutoff_key).value == %{"v" => 0.65}
        refute_receive {:setting_changed, ^model_key, _}
        refute_receive {:setting_changed, ^cutoff_key, _}
      end
    end

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

  defp settings_callback(request) do
    assert {:reply, reply, %{}} = Settings.handle_call(request, {self(), make_ref()}, %{})
    reply
  end

  defp with_real_settings_repo(fun) do
    schema = "settings_real_pool_" <> String.replace(Ecto.UUID.generate(), "-", "")

    {:ok, pool} =
      Repo.start_link(
        name: nil,
        pool: DBConnection.ConnectionPool,
        pool_size: 2,
        parameters: [search_path: schema]
      )

    previous = Repo.put_dynamic_repo(pool)

    try do
      Repo.query!(~s|CREATE SCHEMA "#{schema}"|)

      try do
        Repo.query!("""
        CREATE TABLE "#{schema}".system_settings (
          key text PRIMARY KEY, value jsonb NOT NULL, value_type text NOT NULL,
          description text, updated_at timestamptz
        )
        """)

        fun.(schema)
      after
        Repo.query!(~s|DROP SCHEMA "#{schema}" CASCADE|)
      end
    after
      Repo.put_dynamic_repo(previous)
      GenServer.stop(pool)
    end
  end

  defp delete_cached(keys) do
    Enum.each(keys, &:ets.delete(:backplane_settings, &1))
  end

  defp preserve_cached(keys) do
    previous = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})

    on_exit(fn ->
      for {key, rows} <- previous do
        :ets.delete(:backplane_settings, key)
        :ets.insert(:backplane_settings, rows)
      end
    end)
  end

  defp flush_setting_messages do
    receive do
      {:setting_changed, _key, _value} -> flush_setting_messages()
    after
      0 -> :ok
    end
  end
end
