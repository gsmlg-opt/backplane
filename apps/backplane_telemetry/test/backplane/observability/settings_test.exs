defmodule Backplane.Observability.SettingsTest do
  use BackplaneTelemetry.DataCase, async: false

  alias Backplane.Observability.Settings
  alias Backplane.Settings, as: SystemSettings

  setup do
    Enum.each(observability_keys(), fn key ->
      :ets.delete(:backplane_settings, key)
    end)

    send(SystemSettings, :seed_and_load)
    :sys.get_state(SystemSettings)

    Enum.each(observability_keys(), fn key ->
      Settings.refresh_key(key)
    end)

    :sys.get_state(Settings)

    :ok
  end

  test "defaults keep observability writers disabled" do
    assert Settings.llm_proxy_enabled?() == false
    assert Settings.llm_proxy_persist?() == false
    assert Settings.mcp_proxy_enabled?() == false
    assert Settings.mcp_proxy_persist?() == false
    assert Settings.llm_proxy_retention_days() == 90
    assert Settings.mcp_proxy_retention_days() == 30
    assert Settings.audit_enabled?() == true
    assert Settings.audit_retention_days() == 180
    assert Settings.writer_flush_interval_ms() == 250
    assert Settings.writer_batch_size(:llm_proxy) == 100
    assert Settings.queue_capacity(:llm_proxy) == 10_000
  end

  test "dynamic update applies validated policy" do
    assert :ok = SystemSettings.set("observability.llm_proxy.enabled", true)
    assert :ok = SystemSettings.set("observability.llm_proxy.persist", true)

    for key <- ["observability.llm_proxy.enabled", "observability.llm_proxy.persist"] do
      Settings.refresh_key(key)
    end

    :sys.get_state(Settings)

    assert Settings.llm_proxy_enabled?() == true
    assert Settings.llm_proxy_persist?() == true
  end

  test "invalid values retain the last valid configuration" do
    assert :ok = SystemSettings.set("observability.writer.flush_interval_ms", 500)
    Settings.refresh_key("observability.writer.flush_interval_ms")
    :sys.get_state(Settings)
    assert Settings.writer_flush_interval_ms() == 500

    assert :ok = SystemSettings.set("observability.writer.flush_interval_ms", 10)
    Settings.refresh_key("observability.writer.flush_interval_ms")
    :sys.get_state(Settings)
    assert Settings.writer_flush_interval_ms() == 500
  end

  test "settings unavailable at boot falls back to safe defaults" do
    if pid = Process.whereis(Settings) do
      :ok = GenServer.stop(pid)
    end

    assert Settings.llm_proxy_retention_days() == 90
    assert Settings.writer_batch_size(:mcp_tool_calls) == 500
  end

  defp observability_keys do
    [
      "observability.llm_proxy.enabled",
      "observability.llm_proxy.persist",
      "observability.llm_proxy.retention_days",
      "observability.llm_proxy.payload_mode",
      "observability.llm_proxy.sample_rate",
      "observability.mcp_proxy.enabled",
      "observability.mcp_proxy.persist",
      "observability.mcp_proxy.retention_days",
      "observability.mcp_proxy.payload_mode",
      "observability.mcp_proxy.sample_rate",
      "observability.audit.enabled",
      "observability.audit.retention_days",
      "observability.writer.batch_size",
      "observability.writer.flush_interval_ms",
      "observability.writer.queue_capacity"
    ]
  end
end
