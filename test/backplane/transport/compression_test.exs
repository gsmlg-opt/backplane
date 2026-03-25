defmodule Backplane.Transport.CompressionTest do
  use ExUnit.Case, async: false

  alias Backplane.Transport.Compression

  setup do
    Application.put_env(:backplane, Compression, min_size: 50)

    on_exit(fn ->
      Application.delete_env(:backplane, Compression)
    end)
  end

  describe "call/2" do
    test "compresses response when client accepts gzip and body exceeds threshold" do
      body = String.duplicate("hello world ", 10)

      conn =
        Plug.Test.conn(:get, "/test")
        |> Plug.Conn.put_req_header("accept-encoding", "gzip, deflate")
        |> Compression.call([])
        |> Plug.Conn.send_resp(200, body)

      assert get_header(conn, "content-encoding") == "gzip"
      assert get_header(conn, "vary") == "Accept-Encoding"
      assert :zlib.gunzip(conn.resp_body) == body
    end

    test "does not compress small responses" do
      body = "small"

      conn =
        Plug.Test.conn(:get, "/test")
        |> Plug.Conn.put_req_header("accept-encoding", "gzip")
        |> Compression.call([])
        |> Plug.Conn.send_resp(200, body)

      refute get_header(conn, "content-encoding")
      assert conn.resp_body == body
    end

    test "does not compress when client doesn't accept gzip" do
      body = String.duplicate("hello world ", 10)

      conn =
        Plug.Test.conn(:get, "/test")
        |> Compression.call([])
        |> Plug.Conn.send_resp(200, body)

      refute get_header(conn, "content-encoding")
      assert conn.resp_body == body
    end

    test "passes through init opts" do
      assert Compression.init(foo: :bar) == [foo: :bar]
    end
  end

  defp get_header(conn, key) do
    case Plug.Conn.get_resp_header(conn, key) do
      [value] -> value
      [] -> nil
    end
  end
end
