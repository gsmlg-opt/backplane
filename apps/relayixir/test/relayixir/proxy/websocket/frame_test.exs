defmodule Relayixir.Proxy.WebSocket.FrameTest do
  use ExUnit.Case, async: true

  alias Relayixir.Proxy.WebSocket.Frame

  describe "constructors" do
    test "text/1 creates text frame" do
      frame = Frame.text("hello")
      assert frame.type == :text
      assert frame.payload == "hello"
      assert frame.close_code == nil
      assert frame.close_reason == nil
    end

    test "binary/1 creates binary frame" do
      frame = Frame.binary(<<1, 2, 3>>)
      assert frame.type == :binary
      assert frame.payload == <<1, 2, 3>>
    end

    test "ping/0 creates ping frame with empty payload" do
      frame = Frame.ping()
      assert frame.type == :ping
      assert frame.payload == ""
    end

    test "ping/1 creates ping frame with payload" do
      frame = Frame.ping("ping-data")
      assert frame.type == :ping
      assert frame.payload == "ping-data"
    end

    test "pong/0 creates pong frame with empty payload" do
      frame = Frame.pong()
      assert frame.type == :pong
      assert frame.payload == ""
    end

    test "pong/1 creates pong frame with payload" do
      frame = Frame.pong("pong-data")
      assert frame.type == :pong
      assert frame.payload == "pong-data"
    end

    test "close/0 creates close frame with defaults" do
      frame = Frame.close()
      assert frame.type == :close
      assert frame.close_code == 1000
      assert frame.close_reason == ""
    end

    test "close/2 creates close frame with code and reason" do
      frame = Frame.close(1001, "Going Away")
      assert frame.type == :close
      assert frame.close_code == 1001
      assert frame.close_reason == "Going Away"
    end
  end

  describe "from_mint/1" do
    test "converts text tuple" do
      frame = Frame.from_mint({:text, "hello"})
      assert frame == Frame.text("hello")
    end

    test "converts binary tuple" do
      frame = Frame.from_mint({:binary, <<1, 2>>})
      assert frame == Frame.binary(<<1, 2>>)
    end

    test "converts ping tuple" do
      frame = Frame.from_mint({:ping, "data"})
      assert frame == Frame.ping("data")
    end

    test "converts pong tuple" do
      frame = Frame.from_mint({:pong, "data"})
      assert frame == Frame.pong("data")
    end

    test "converts close tuple with code and reason" do
      frame = Frame.from_mint({:close, 1000, "normal"})
      assert frame == Frame.close(1000, "normal")
    end

    test "converts bare :close atom" do
      frame = Frame.from_mint(:close)
      assert frame == Frame.close(1000, "")
    end
  end

  describe "to_mint/1" do
    test "converts text frame" do
      assert Frame.to_mint(Frame.text("hello")) == {:text, "hello"}
    end

    test "converts binary frame" do
      assert Frame.to_mint(Frame.binary(<<1, 2>>)) == {:binary, <<1, 2>>}
    end

    test "converts ping frame" do
      assert Frame.to_mint(Frame.ping("data")) == {:ping, "data"}
    end

    test "converts pong frame" do
      assert Frame.to_mint(Frame.pong("data")) == {:pong, "data"}
    end

    test "converts close frame" do
      assert Frame.to_mint(Frame.close(1001, "Going Away")) == {:close, 1001, "Going Away"}
    end
  end

  describe "to_websock/1" do
    test "converts text frame" do
      assert Frame.to_websock(Frame.text("hello")) == {:text, "hello"}
    end

    test "converts binary frame" do
      assert Frame.to_websock(Frame.binary(<<1, 2>>)) == {:binary, <<1, 2>>}
    end

    test "converts ping frame" do
      assert Frame.to_websock(Frame.ping("data")) == {:ping, "data"}
    end

    test "converts pong frame" do
      assert Frame.to_websock(Frame.pong("data")) == {:pong, "data"}
    end

    test "converts close frame" do
      assert Frame.to_websock(Frame.close(1000, "bye")) == {:close, 1000, "bye"}
    end
  end

  describe "from_websock/1" do
    test "converts text tuple" do
      assert Frame.from_websock({:text, "hello"}) == Frame.text("hello")
    end

    test "converts binary tuple" do
      assert Frame.from_websock({:binary, <<1, 2>>}) == Frame.binary(<<1, 2>>)
    end

    test "converts ping tuple" do
      assert Frame.from_websock({:ping, "data"}) == Frame.ping("data")
    end

    test "converts pong tuple" do
      assert Frame.from_websock({:pong, "data"}) == Frame.pong("data")
    end
  end

  describe "roundtrip conversions" do
    test "mint roundtrip for text" do
      original = Frame.text("test")
      assert original == Frame.from_mint(Frame.to_mint(original))
    end

    test "mint roundtrip for binary" do
      original = Frame.binary(<<1, 2, 3>>)
      assert original == Frame.from_mint(Frame.to_mint(original))
    end

    test "mint roundtrip for close" do
      original = Frame.close(1001, "Going Away")
      assert original == Frame.from_mint(Frame.to_mint(original))
    end

    test "websock roundtrip for text" do
      original = Frame.text("test")
      assert original == Frame.from_websock(Frame.to_websock(original))
    end

    test "websock roundtrip for binary" do
      original = Frame.binary(<<1, 2, 3>>)
      assert original == Frame.from_websock(Frame.to_websock(original))
    end
  end
end
