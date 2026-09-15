defmodule Backplane.Observability.FlagsTest do
  use ExUnit.Case, async: false

  alias Backplane.Observability.Flags

  @flags [
    :observability_v2_enabled,
    :observability_v2_llm_write,
    :observability_v2_mcp_write,
    :observability_v2_runtime_sink,
    :use_legacy_telemetry_logger
  ]

  @test_disabled :observability_v2_test_disabled
  @policy_keys [
    "observability.llm_proxy.enabled",
    "observability.llm_proxy.persist",
    "observability.mcp_proxy.enabled",
    "observability.mcp_proxy.persist"
  ]

  setup do
    previous =
      Enum.map(@flags, fn flag -> {flag, Application.get_env(:backplane_telemetry, flag)} end)

    previous_test_disabled = Application.get_env(:backplane_telemetry, @test_disabled)

    previous_policy =
      Enum.map(@policy_keys, fn key ->
        {key, :ets.lookup(:backplane_observability_settings, key)}
      end)

    Enum.each(@policy_keys, fn key ->
      :ets.insert(:backplane_observability_settings, {key, false})
    end)

    on_exit(fn ->
      Enum.each(previous, fn
        {flag, nil} -> Application.delete_env(:backplane_telemetry, flag)
        {flag, value} -> Application.put_env(:backplane_telemetry, flag, value)
      end)

      if is_nil(previous_test_disabled) do
        Application.delete_env(:backplane_telemetry, @test_disabled)
      else
        Application.put_env(:backplane_telemetry, @test_disabled, previous_test_disabled)
      end

      Enum.each(previous_policy, fn
        {key, []} -> :ets.delete(:backplane_observability_settings, key)
        {_key, rows} -> :ets.insert(:backplane_observability_settings, rows)
      end)
    end)

    :ok
  end

  test "defaults keep Observability v2 disabled" do
    Enum.each(@flags, fn flag ->
      Application.put_env(:backplane_telemetry, flag, false)
    end)

    assert Flags.enabled?() == false
    assert Flags.llm_write?() == false
    assert Flags.mcp_write?() == false
    assert Flags.runtime_sink?() == false

    assert Flags.snapshot() == %{
             observability_v2_enabled: false,
             observability_v2_llm_write: false,
             observability_v2_mcp_write: false,
             observability_v2_runtime_sink: false,
             use_legacy_telemetry_logger: false
           }
  end

  test "test override disables settings-backed observability" do
    Application.put_env(:backplane_telemetry, :observability_v2_enabled, true)
    Application.put_env(:backplane_telemetry, :observability_v2_llm_write, true)
    Application.put_env(:backplane_telemetry, :observability_v2_mcp_write, true)
    Application.put_env(:backplane_telemetry, :observability_v2_runtime_sink, true)
    Application.put_env(:backplane_telemetry, @test_disabled, true)

    refute Flags.enabled?()
    refute Flags.llm_write?()
    refute Flags.mcp_write?()
    refute Flags.runtime_sink?()
  end

  test "domain writes require the master switch; runtime sink follows enabled policy" do
    Application.put_env(:backplane_telemetry, :observability_v2_enabled, false)
    Application.put_env(:backplane_telemetry, :observability_v2_llm_write, true)
    Application.put_env(:backplane_telemetry, :observability_v2_mcp_write, true)
    Application.put_env(:backplane_telemetry, :observability_v2_runtime_sink, true)

    refute Flags.enabled?()
    refute Flags.llm_write?()
    refute Flags.mcp_write?()
    refute Flags.runtime_sink?()

    Application.put_env(:backplane_telemetry, :observability_v2_enabled, true)

    assert Flags.enabled?()
    assert Flags.llm_write?()
    assert Flags.mcp_write?()
    assert Flags.runtime_sink?()
  end

  test "use_legacy_telemetry_logger suppresses runtime sink even when enabled" do
    Application.put_env(:backplane_telemetry, :observability_v2_enabled, true)
    Application.put_env(:backplane_telemetry, :observability_v2_runtime_sink, true)
    Application.put_env(:backplane_telemetry, :use_legacy_telemetry_logger, true)

    assert Flags.enabled?()
    refute Flags.runtime_sink?()
  end
end
