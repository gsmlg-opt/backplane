defmodule Backplane.Audio.RouteParserTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.Audio.RouteParser
  alias Backplane.LLM.Router

  test "speech parser rejects duplicate JSON keys and near-match content types" do
    conn =
      conn(:post, "/v1/audio/speech", ~s({"model":"one","model":"two","input":"hi","voice":"v"}))
      |> put_req_header("content-type", "application/json")
      |> RouteParser.call([])

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "duplicate_parameter"

    conn =
      conn(:post, "/v1/audio/speech", "{}")
      |> put_req_header("content-type", "application/jsonp")
      |> RouteParser.call([])

    assert conn.status == 415
  end

  test "multipart rejects missing boundary and deletes upload on later duplicate field" do
    conn =
      conn(:post, "/v1/audio/transcriptions", "body")
      |> put_req_header("content-type", "multipart/form-data")
      |> RouteParser.call([])

    assert conn.status == 415

    body =
      multipart([
        {"file", "clip.wav", "audio/wav", "RIFFfake"},
        {"model", nil, nil, "one"},
        {"model", nil, nil, "two"}
      ])

    conn =
      conn(:post, "/v1/audio/transcriptions", body)
      |> put_req_header("content-type", "multipart/form-data; boundary=test-boundary")
      |> RouteParser.call([])

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "duplicate_parameter"
  end

  test "authentication rejects malformed multipart before parsing" do
    token = Application.get_env(:backplane, :auth_token)
    Application.put_env(:backplane, :auth_token, "expected-audio-token")

    on_exit(fn ->
      if is_nil(token),
        do: Application.delete_env(:backplane, :auth_token),
        else: Application.put_env(:backplane, :auth_token, token)
    end)

    conn =
      conn(:post, "/v1/audio/transcriptions", "not multipart")
      |> put_req_header("content-type", "multipart/form-data; boundary=test-boundary")
      |> put_req_header("authorization", "Bearer wrong")
      |> Router.call(Router.init([]))

    assert conn.status == 401
    assert conn.body_params == %Plug.Conn.Unfetched{aspect: :body_params}
  end

  test "strict MIME parsing rejects empty, oversized and malformed boundaries" do
    for type <- [
          "multipart/form-data; boundary=",
          ~s(multipart/form-data; boundary=""),
          "multipart/form-data; boundary=" <> String.duplicate("x", 71),
          "multipart/form-data-wrong; boundary=x"
        ] do
      conn =
        conn(:post, "/v1/audio/transcriptions", "x")
        |> put_req_header("content-type", type)
        |> RouteParser.call([])

      assert conn.status == 415
    end
  end

  test "empty unsupported options reach consistent validation while meaningful ones fail" do
    for prompt <- ["", "do this"] do
      conn =
        conn(
          :post,
          "/v1/audio/transcriptions",
          multipart([
            {"model", nil, nil, "asr"},
            {"file", "x.wav", nil, "bytes"},
            {"prompt", nil, nil, prompt}
          ])
        )
        |> put_req_header("content-type", "multipart/form-data; boundary=test-boundary")
        |> RouteParser.call([])

      assert conn.status == nil

      try do
        if prompt == "",
          do: assert({:ok, _} = Backplane.Audio.Request.transcription(conn.body_params)),
          else:
            assert(
              {:error, %{param: "prompt"}} =
                Backplane.Audio.Request.transcription(conn.body_params)
            )
      after
        Plug.Upload.delete(conn.body_params["file"])
        Backplane.Audio.AccessLifecycle.finish(conn.private.audio_observer, :cancelled, nil)
        Backplane.Audio.Media.Session.release(conn.private.audio_session)
      end
    end
  end

  defp multipart(parts) do
    Enum.map_join(parts, "", fn {name, filename, content_type, body} ->
      disposition =
        if filename,
          do: ~s(content-disposition: form-data; name="#{name}"; filename="#{filename}"),
          else: ~s(content-disposition: form-data; name="#{name}")

      type = if content_type, do: "content-type: #{content_type}\r\n", else: ""
      "--test-boundary\r\n#{disposition}\r\n#{type}\r\n#{body}\r\n"
    end) <> "--test-boundary--\r\n"
  end
end
