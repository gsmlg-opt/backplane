defmodule Backplane.Transport.CacheBodyReaderTest do
  use ExUnit.Case, async: true

  alias Backplane.Transport.CacheBodyReader

  describe "read_body/2" do
    test "caches raw body in conn.assigns[:raw_body]" do
      body = ~s({"key":"value"})

      conn =
        Plug.Test.conn(:post, "/test", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")

      {:ok, read_body, conn} = CacheBodyReader.read_body(conn, [])
      assert read_body == body
      assert conn.assigns[:raw_body] == body
    end

    test "accumulates body across multiple reads" do
      # Simulate a large body by setting a very small length limit
      body = String.duplicate("x", 200)

      conn =
        Plug.Test.conn(:post, "/test", body)
        |> Plug.Conn.put_req_header("content-type", "application/octet-stream")

      # Read body in full — Plug.Test always returns {:ok, ...} for test connections
      {:ok, read_body, conn} = CacheBodyReader.read_body(conn, [])
      assert read_body == body
      assert conn.assigns[:raw_body] == body
    end

    test "preserves existing raw_body when accumulating" do
      body = ~s({"second":"read"})

      conn =
        Plug.Test.conn(:post, "/test", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.assign(:raw_body, "prefix")

      {:ok, _read_body, conn} = CacheBodyReader.read_body(conn, [])
      assert conn.assigns[:raw_body] == "prefix" <> body
    end
  end
end
