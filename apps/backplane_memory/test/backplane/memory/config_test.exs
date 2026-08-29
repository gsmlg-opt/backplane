defmodule Backplane.Memory.ConfigTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Config
  alias Backplane.Settings
  alias Backplane.Settings.Setting

  @settings_table :backplane_settings

  @numeric_settings [
    {:event_gap_grace_seconds, "memory.event_gap_grace_seconds", 60, 1, 3_600},
    {:host_batch_max_events, "memory.host_batch_max_events", 100, 1, 100},
    {:host_batch_max_bytes, "memory.host_batch_max_bytes", 524_288, 1, 524_288},
    {:host_spool_max_bytes, "memory.host_spool_max_bytes", 67_108_864, 1, 1_073_741_824},
    {:host_spool_max_age_days, "memory.host_spool_max_age_days", 30, 1, 3_660},
    {:session_stale_after_seconds, "memory.session_stale_after_seconds", 10_800, 60, 10_800},
    {:fallback_sweep_batch_size, "memory.fallback_sweep_batch_size", 100, 1, 500},
    {:activity_retention_days, "memory.activity_retention_days", 730, 1, 3_660},
    {:recall_trace_retention_days, "memory.recall_trace_retention_days", 30, 1, 3_660},
    {:recall_rrf_k, "memory.recall_rrf_k", 60, 1, 1_000},
    {:recall_max_per_session, "memory.recall_max_per_session", 3, 1, 100},
    {:recall_token_budget, "memory.recall_token_budget", 4_096, 1, 100_000},
    {:recall_reranker_top_k, "memory.recall_reranker_top_k", 20, 1, 500},
    {:replay_max_events, "memory.replay_max_events", 1_000, 1, 10_000},
    {:replay_import_max_files, "memory.replay_import_max_files", 200, 1, 1_000},
    {:replay_import_max_entries, "memory.replay_import_max_entries", 100_000, 1, 1_000_000},
    {:replay_import_max_bytes, "memory.replay_import_max_bytes", 1_073_741_824, 1,
     1_073_741_824}
  ]

  @recall_flags [
    {:recall_trace_enabled?, "memory.recall_trace_enabled", true},
    {:recall_reranker_enabled?, "memory.recall_reranker_enabled", false}
  ]

  @replay_flags [
    {:replay_enabled?, "memory.replay_enabled", true},
    {:replay_import_enabled?, "memory.replay_import_enabled", false}
  ]

  @flags [
    {:pipeline_enabled?, "memory.pipeline.enabled"},
    {:events_enabled?, "memory.events.enabled"},
    {:dual_write?, "memory.events.dual_write"},
    {:window_summaries_enabled?, "memory.window_summaries.enabled"},
    {:session_summary_v2_enabled?, "memory.session_summary_v2.enabled"},
    {:fact_extraction_v2_enabled?, "memory.fact_extraction_v2.enabled"},
    {:procedure_extraction_v2_enabled?, "memory.procedure_extraction_v2.enabled"},
    {:relation_classifier_enabled?, "memory.relation_classifier.enabled"},
    {:recall_v2_enabled?, "memory.recall_v2.enabled"}
  ]

  @children tl(@flags)
  @independent_children Enum.drop(@flags, 3)

  setup do
    send(Settings, :seed_and_load)
    :sys.get_state(Settings)

    snapshot =
      (@flags ++
         @recall_flags ++
         @replay_flags ++
         Enum.map(@numeric_settings, fn {accessor, key, _, _, _} -> {accessor, key} end) ++
         [
           {:recall_channel_weights, "memory.recall_channel_weights"},
           {:recall_channel_limits, "memory.recall_channel_limits"}
         ])
      |> Map.new(fn setting ->
        key = elem(setting, 1)
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

    Enum.each(snapshot, fn {key, _rows} -> :ets.delete(@settings_table, key) end)

    :ok
  end

  test "recall booleans have typed defaults and reject truthy non-booleans" do
    for {accessor, key, default} <- @recall_flags do
      assert apply(Config, accessor, []) == default

      assert %Setting{value: %{"v" => ^default}, value_type: "boolean"} =
               repo().get!(Setting, key)

      put_setting(key, not default)
      assert apply(Config, accessor, []) == not default

      for invalid <- [nil, "true", 1, %{}] do
        put_setting(key, invalid)
        assert apply(Config, accessor, []) == default
      end
    end
  end

  test "replay flags are strict and import depends on replay" do
    put_setting("memory.pipeline.enabled", true)

    for {accessor, key, default} <- @replay_flags do
      assert apply(Config, accessor, []) == default
      put_setting(key, not default)
      assert apply(Config, accessor, []) == not default
      put_setting(key, "true")
      assert apply(Config, accessor, []) == default
      :ets.delete(@settings_table, key)
    end

    put_setting("memory.replay_import_enabled", true)
    put_setting("memory.replay_enabled", false)
    refute Config.replay_import_enabled?()
  end

  test "recall channel weights and limits are typed complete maps with strict bounds" do
    assert Config.recall_channel_weights() == %{fts: 1.0, vector: 1.0, graph: 1.0}
    assert Config.recall_channel_limits() == %{fts: 50, vector: 50, graph: 50}

    assert %Setting{
             value_type: "json",
             value: %{"v" => %{"fts" => 1.0, "vector" => 1.0, "graph" => 1.0}}
           } =
             repo().get!(Setting, "memory.recall_channel_weights")

    assert %Setting{
             value_type: "json",
             value: %{"v" => %{"fts" => 50, "vector" => 50, "graph" => 50}}
           } =
             repo().get!(Setting, "memory.recall_channel_limits")

    put_setting("memory.recall_channel_weights", %{"fts" => 2, "vector" => 0.5, "graph" => 0})
    assert Config.recall_channel_weights() == %{fts: 2.0, vector: 0.5, graph: 0.0}

    put_setting("memory.recall_channel_limits", %{"fts" => 1, "vector" => 250, "graph" => 500})
    assert Config.recall_channel_limits() == %{fts: 1, vector: 250, graph: 500}

    for invalid <- [
          %{"fts" => 1.0},
          %{"fts" => -1, "vector" => 1, "graph" => 1},
          %{"fts" => 0, "vector" => 0, "graph" => 0},
          %{"fts" => 1, "vector" => 1, "graph" => 1, "other" => 1},
          %{"fts" => "1", "vector" => 1, "graph" => 1},
          nil
        ] do
      put_setting("memory.recall_channel_weights", invalid)
      assert Config.recall_channel_weights() == %{fts: 1.0, vector: 1.0, graph: 1.0}
    end

    for invalid <- [
          %{"fts" => 1, "vector" => 1},
          %{"fts" => 0, "vector" => 1, "graph" => 1},
          %{"fts" => 1, "vector" => 1, "graph" => 501},
          %{"fts" => 1.0, "vector" => 1, "graph" => 1},
          nil
        ] do
      put_setting("memory.recall_channel_limits", invalid)
      assert Config.recall_channel_limits() == %{fts: 50, vector: 50, graph: 50}
    end
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

  test "numeric memory settings have typed defaults and documented bounds" do
    for {accessor, key, default, minimum, maximum} <- @numeric_settings do
      assert apply(Config, accessor, []) == default

      assert %Setting{
               value: %{"v" => ^default},
               value_type: "integer",
               description: description
             } = repo().get!(Setting, key)

      assert description =~ "#{minimum}..#{maximum}"
    end
  end

  test "numeric accessors accept only integers within their inclusive bounds" do
    for {accessor, key, default, minimum, maximum} <- @numeric_settings do
      for valid <- [minimum, maximum] do
        put_setting(key, valid)
        assert apply(Config, accessor, []) == valid
      end

      for invalid <- [minimum - 1, maximum + 1, nil, "#{default}", 1.0, true] do
        put_setting(key, invalid)
        assert apply(Config, accessor, []) == default
      end
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
