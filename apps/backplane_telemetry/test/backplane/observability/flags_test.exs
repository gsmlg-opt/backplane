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

  setup do
    previous =
      Enum.map(@flags, fn flag -> {flag, Application.get_env(:backplane_telemetry, flag)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {flag, nil} -> Application.delete_env(:backplane_telemetry, flag)
        {flag, value} -> Application.put_env(:backplane_telemetry, flag, value)
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
