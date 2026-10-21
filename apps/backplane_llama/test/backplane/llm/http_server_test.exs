defmodule BackplaneLlama.Test.HTTPServerTest do
  use ExUnit.Case, async: false

  alias BackplaneLlama.Test.HTTPServer

  test "receives embeddings over loopback with callback assertions and exactly one request" do
    server =
      HTTPServer.open("POST", "/v1/embeddings", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"input" => ["fixture evidence"]}
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"embedding" => [0.1, 0.2]}]}))
      end)

    response =
      Req.post!("http://127.0.0.1:#{server.port}/v1/embeddings",
        json: %{input: ["fixture evidence"]},
        headers: [{"authorization", "Bearer fixture-token"}],
        retry: false
      )

    assert response.status == 200
    assert response.body == %{"data" => [%{"embedding" => [0.1, 0.2]}]}
  end
end
