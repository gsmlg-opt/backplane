defmodule Backplane.Memory.OperatorConfigTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Config
  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  @context %{
    actor: "trusted-admin:test",
    request_id: "config-test",
    correlation_id: "config-test"
  }

  setup do
    snapshot = :ets.tab2list(:backplane_settings)

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_settings)
      :ets.insert(:backplane_settings, snapshot)
    end)

    :ok
  end

  test "operator inventory includes actual gates, routes, credential references and bounds" do
    entries = Map.new(Config.editable_settings(), &{&1.key, &1})

    for key <- ~w(services.memory.enabled memory.pipeline.enabled memory.events.enabled
                  memory.window_summaries.enabled memory.session_summary_v2.enabled
                  memory.fact_extraction_v2.enabled memory.procedure_extraction_v2.enabled
                  memory.relation_classifier.enabled memory.recall_v2.enabled
                  memory.host_sync_v2.enabled memory.llm_model memory.embed_model
                  memory.proxy_credential memory.lesson_decay_archive_days
                  memory.session_stale_after_seconds memory.recall_token_budget) do
      assert Map.has_key?(entries, key), "missing operator setting #{key}"
      assert is_binary(entries[key].apply_mode)
      assert is_binary(entries[key].reason)
    end

    assert entries["memory.llm_model"].type == :model
    assert entries["memory.proxy_credential"].type == :credential
  end

  test "config cannot bypass guarded dual-write confirmation" do
    assert {:error, :requires_pipeline_controls} =
             Config.update_setting("memory.events.dual_write", "true", @context)
  end

  test "model strings are normalized and bounded; credential references must be safe service keys" do
    assert {:ok, "provider/model"} =
             Config.update_setting("memory.llm_model", " provider/model ", @context)

    assert Settings.get("memory.llm_model") == "provider/model"

    assert {:error, :invalid_value} =
             Config.update_setting("memory.embed_model", String.duplicate("x", 257), @context)

    assert {:error, :invalid_value} =
             Config.update_setting("memory.llm_model", "bad\nmodel", @context)

    assert {:error, :invalid_value} =
             Config.update_setting("memory.proxy_credential", "nonexistent-config-key", @context)

    name = "memory-config-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Credentials.store(name, "never-render-this", "service")
    assert {:ok, ^name} = Config.update_setting("memory.proxy_credential", name, @context)
    refute inspect(Config.editable_settings()) =~ "never-render-this"
    assert {:ok, nil} = Config.update_setting("memory.proxy_credential", "", @context)
    assert {:ok, nil} = Config.update_setting("memory.llm_model", "  ", @context)
  end
end
