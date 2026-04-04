defmodule Relayixir.Proxy.WebSocket.CloseTest do
  use ExUnit.Case, async: true

  alias Relayixir.Proxy.WebSocket.Close
  alias Relayixir.Proxy.WebSocket.Frame

  describe "normal_close_code?/1" do
    test "1000 is normal" do
      assert Close.normal_close_code?(1000) == true
    end

    test "1001 is normal" do
      assert Close.normal_close_code?(1001) == true
    end

    test "1002 is not normal" do
      assert Close.normal_close_code?(1002) == false
    end

    test "1011 is not normal" do
      assert Close.normal_close_code?(1011) == false
    end

    test "1014 is not normal" do
      assert Close.normal_close_code?(1014) == false
    end

    test "nil is not normal" do
      assert Close.normal_close_code?(nil) == false
    end
  end

  describe "upstream_failure_code/0" do
    test "returns 1014" do
      assert Close.upstream_failure_code() == 1014
    end
  end

  describe "internal_error_code/0" do
    test "returns 1011" do
      assert Close.internal_error_code() == 1011
    end
  end

  describe "close_timeout/0" do
    test "returns default close timeout" do
      assert Close.close_timeout() == 5_000
    end
  end

  describe "upstream_connect_failed_frame/0" do
    test "returns close frame with 1014 code" do
      frame = Close.upstream_connect_failed_frame()
      assert %Frame{type: :close, close_code: 1014, close_reason: "Bad Gateway"} = frame
    end
  end

  describe "internal_error_frame/0" do
    test "returns close frame with 1011 code" do
      frame = Close.internal_error_frame()
      assert %Frame{type: :close, close_code: 1011, close_reason: "Internal Error"} = frame
    end
  end

  describe "normal_close_frame/0" do
    test "returns close frame with 1000 code" do
      frame = Close.normal_close_frame()
      assert %Frame{type: :close, close_code: 1000, close_reason: ""} = frame
    end
  end

  describe "shutdown_action/3" do
    test "downstream_close propagates to upstream" do
      result = Close.shutdown_action(:downstream_close, 1000, "bye")

      assert {:propagate_to_upstream, %Frame{type: :close, close_code: 1000, close_reason: "bye"}} =
               result
    end

    test "upstream_close propagates to downstream" do
      result = Close.shutdown_action(:upstream_close, 1000, "bye")

      assert {:propagate_to_downstream,
              %Frame{type: :close, close_code: 1000, close_reason: "bye"}} = result
    end

    test "upstream_failure propagates 1014 to downstream" do
      result = Close.shutdown_action(:upstream_failure, 0, "")

      assert {:propagate_to_downstream,
              %Frame{type: :close, close_code: 1014, close_reason: "Bad Gateway"}} = result
    end

    test "handler_death terminates immediately" do
      result = Close.shutdown_action(:handler_death, 0, "")
      assert result == :terminate
    end
  end
end
