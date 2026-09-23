defmodule Backplane.LLM.Antigravity.RequestBoundaryTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test
  alias Backplane.LLM.Antigravity.{RequestAuthPlug, RequestTarget}

  @path "/antigravity/providers/account/v1internal:generateContent"

  test "rejects unsupported and ambiguous paths without guessing an RPC" do
    for path <- [
          @path <> "/extra",
          "/antigravity/providers/../v1internal:generateContent",
          "/antigravity/providers/account/v1internal:countTokens",
          "/antigravity/providers/account/v1internal:%67enerateContent",
          "/antigravity/providers/account%2fother/v1internal:generateContent"
        ] do
      assert {:error, _} = RequestTarget.parse("POST", path, "")
    end

    assert {:error, _} = RequestTarget.parse("GET", @path, "")
  end

  test "redacts query credentials and rejects all queries except the stream selector" do
    for query <- [
          "key=private",
          "%6bey=private",
          "alt=sse&key=private",
          "alt=sse&alt=sse",
          "alt=json",
          "project=other"
        ] do
      result = conn(:post, @path <> "?" <> query) |> RequestAuthPlug.call([])
      assert result.halted
      assert result.status == 400
      assert result.query_string == ""
      refute result.resp_body =~ "private"
    end

    stream = "/antigravity/providers/account/v1internal:streamGenerateContent"

    for query <- ["", "alt=sse"] do
      assert {:ok, %{operation: :stream_generate_content}} =
               RequestTarget.parse("POST", stream, query)
    end
  end

  test "rejects duplicate and conflicting credentials without exposing them" do
    for headers <- [
          [{"authorization", "Bearer private"}, {"authorization", "Bearer second"}],
          [{"authorization", "Bearer private"}, {"x-goog-api-key", "second"}],
          [{"x-api-key", "private"}],
          [{"api-key", "private"}]
        ] do
      result = %{conn(:post, @path) | req_headers: headers} |> RequestAuthPlug.call([])
      assert result.status == 400
      refute result.resp_body =~ "private"
    end
  end
end
