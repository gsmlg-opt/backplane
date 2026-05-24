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

    test "includes result status :ok on success" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-result-ok-#{inspect(ref)}",
        [:backplane, :tool_call, :stop],
        fn _event, _measurements, metadata, _config ->
          send(self_pid, {:result_status, metadata.result})
        end,
        nil
      )

      Telemetry.span_tool_call("test::tool", fn -> {:ok, "done"} end)

      assert_receive {:result_status, :ok}

      :telemetry.detach("test-result-ok-#{inspect(ref)}")
    end

    test "includes result status :error on failure" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-result-err-#{inspect(ref)}",
        [:backplane, :tool_call, :stop],
        fn _event, _measurements, metadata, _config ->
          send(self_pid, {:result_status, metadata.result})
        end,
        nil
      )

      Telemetry.span_tool_call("test::tool", fn -> {:error, "fail"} end)

      assert_receive {:result_status, :error}

      :telemetry.detach("test-result-err-#{inspect(ref)}")
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

  describe "mcp_request events" do
    test "emits [:backplane, :mcp_request, :start] with method" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-mcp-#{inspect(ref)}",
        [:backplane, :mcp_request, :start],
        fn _event, measurements, metadata, _config ->
          send(self_pid, {:mcp, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit_mcp_request("tools/list")

      assert_receive {:mcp, %{system_time: _}, %{method: "tools/list"}}

      :telemetry.detach("test-mcp-#{inspect(ref)}")
    end

    test "includes custom metadata" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-mcp-meta-#{inspect(ref)}",
        [:backplane, :mcp_request, :start],
        fn _event, _measurements, metadata, _config ->
          send(self_pid, {:mcp_meta, metadata})
        end,
        nil
      )

      Telemetry.emit_mcp_request("initialize", %{session: "abc"})

      assert_receive {:mcp_meta, %{method: "initialize", session: "abc"}}

      :telemetry.detach("test-mcp-meta-#{inspect(ref)}")
    end
  end

  describe "sse_stream events" do
    test "emits [:backplane, :sse_stream, :start] with tool name" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-sse-start-#{inspect(ref)}",
        [:backplane, :sse_stream, :start],
        fn _event, measurements, metadata, _config ->
          send(self_pid, {:sse_start, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit_sse_start("docs::query-docs")

      assert_receive {:sse_start, %{system_time: _}, %{tool: "docs::query-docs"}}

      :telemetry.detach("test-sse-start-#{inspect(ref)}")
    end

    test "emits [:backplane, :sse_stream, :stop] with duration" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-sse-stop-#{inspect(ref)}",
        [:backplane, :sse_stream, :stop],
        fn _event, measurements, metadata, _config ->
          send(self_pid, {:sse_stop, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit_sse_stop("docs::query-docs", 42_000)

      assert_receive {:sse_stop, %{duration: 42_000}, %{tool: "docs::query-docs"}}

      :telemetry.detach("test-sse-stop-#{inspect(ref)}")
    end
  end
end
