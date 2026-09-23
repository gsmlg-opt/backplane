defmodule Backplane.LLM.Google.RequestAuthPlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.Google.RequestAuthPlug

  test "adapts one SDK x-goog-api-key to the Backplane bearer credential" do
    conn =
      :post
      |> conn("/v1beta/models/gemini:generateContent", "{}")
      |> put_req_header("x-goog-api-key", "backplane-client-token")
      |> RequestAuthPlug.call([])

    assert get_req_header(conn, "authorization") == ["Bearer backplane-client-token"]
    assert get_req_header(conn, "x-goog-api-key") == []
    refute conn.halted
  end

  test "fails closed for repeated or conflicting credential carriers" do
    repeated =
      :post
      |> conn("/v1beta/models/gemini:generateContent", "{}")
      |> prepend_req_headers([
        {"x-goog-api-key", "one"},
        {"x-goog-api-key", "two"}
      ])
      |> RequestAuthPlug.call([])

    assert repeated.status == 400
    assert Jason.decode!(repeated.resp_body)["error"]["status"] == "INVALID_ARGUMENT"

    conflicting =
      :post
      |> conn("/v1beta/models/gemini:generateContent", "{}")
      |> put_req_header("x-goog-api-key", "one")
      |> put_req_header("authorization", "Bearer two")
      |> RequestAuthPlug.call([])

    assert conflicting.status == 400

    unsupported =
      :post
      |> conn("/v1beta/models/gemini:generateContent", "{}")
      |> put_req_header("x-api-key", "unsupported")
      |> RequestAuthPlug.call([])

    assert unsupported.status == 400
  end

  test "rejects query key before later endpoint telemetry and removes it from the conn" do
    conn =
      :post
      |> conn("/v1beta/models/gemini:generateContent?key=secret&alt=sse", "{}")
      |> RequestAuthPlug.call([])

    assert conn.status == 400
    assert conn.halted
    refute conn.query_string =~ "secret"
    assert Jason.decode!(conn.resp_body)["error"]["status"] == "INVALID_ARGUMENT"
  end

  test "does not affect non-Google routes" do
    conn =
      :post
      |> conn("/v1/responses", "{}")
      |> put_req_header("x-goog-api-key", "unchanged")
      |> RequestAuthPlug.call([])

    assert get_req_header(conn, "x-goog-api-key") == ["unchanged"]
    refute conn.halted
  end
end
