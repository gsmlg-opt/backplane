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
    {:fallback_sweep_batch_size, "memory.fallback_sweep_batch_size", 100, 1, 500}
  ]

  @editable_keys ~w(
    services.memory.enabled memory.llm_model memory.embed_model memory.proxy_credential
    memory.session_stale_after_seconds memory.fallback_sweep_batch_size
    memory.host_batch_max_events memory.host_batch_max_bytes memory.host_spool_max_bytes
    memory.host_spool_max_age_days memory.event_gap_grace_seconds
  )

  setup do
    send(Settings, :seed_and_load)
    :sys.get_state(Settings)

    snapshot =
      Map.new(@numeric_settings, fn {_accessor, key, _, _, _} ->
        {key, :ets.lookup(@settings_table, key)}
      end)

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(@settings_table, key)
        if rows != [], do: :ets.insert(@settings_table, rows)
      end)
    end)

    Enum.each(snapshot, fn {key, _rows} -> :ets.delete(@settings_table, key) end)
    :ok
  end

  test "editable settings are limited to the retained memory keys" do
    assert Enum.map(Config.editable_settings(), & &1.key) |> Enum.sort() ==
             Enum.sort(@editable_keys)
  end

  test "retired memory settings are no longer seeded" do
    for key <-
          ~w(memory.pipeline.enabled memory.recall.enabled memory.host_sync.enabled memory.lesson_auto_extract memory.crystals_enabled memory.replay_enabled memory.recall_relevance_vector_min) do
      assert repo().get(Setting, key) == nil, "#{key} should not be seeded"
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

  defp put_setting(key, value), do: :ets.insert(@settings_table, {key, value})
end
