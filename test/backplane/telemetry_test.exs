defmodule Backplane.TelemetryTest do
  use ExUnit.Case, async: true

  alias Backplane.Telemetry

  describe "tool_call events" do
    test "emits [:backplane, :tool_call, :start] on dispatch" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-start-#{inspect(ref)}",
        [:backplane, :tool_call, :start],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.span_tool_call("test::tool", fn -> :ok end)

      assert_receive {:telemetry, [:backplane, :tool_call, :start], %{system_time: _},
                      %{tool: "test::tool"}}

      :telemetry.detach("test-start-#{inspect(ref)}")
    end

    test "emits [:backplane, :tool_call, :stop] on success" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-stop-#{inspect(ref)}",
        [:backplane, :tool_call, :stop],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.span_tool_call("test::tool", fn -> {:ok, "result"} end)

      assert_receive {:telemetry, [:backplane, :tool_call, :stop], %{duration: _},
                      %{tool: "test::tool"}}

      :telemetry.detach("test-stop-#{inspect(ref)}")
    end

    test "emits [:backplane, :tool_call, :exception] on error" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-exception-#{inspect(ref)}",
        [:backplane, :tool_call, :exception],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      assert_raise RuntimeError, fn ->
        Telemetry.span_tool_call("test::tool", fn -> raise "boom" end)
      end

      assert_receive {:telemetry, [:backplane, :tool_call, :exception], %{duration: _},
                      %{tool: "test::tool", kind: :error}}

      :telemetry.detach("test-exception-#{inspect(ref)}")
    end

    test "includes tool name and duration in metadata" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-meta-#{inspect(ref)}",
        [:backplane, :tool_call, :stop],
        fn _event, measurements, metadata, _config ->
          send(self_pid, {:meta, measurements, metadata})
        end,
        nil
      )

      Telemetry.span_tool_call("my::tool", fn -> :ok end)

      assert_receive {:meta, %{duration: duration}, %{tool: "my::tool"}}
      assert is_integer(duration)
      assert duration >= 0

      :telemetry.detach("test-meta-#{inspect(ref)}")
    end
  end
end
