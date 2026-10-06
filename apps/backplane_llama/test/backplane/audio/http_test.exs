defmodule Backplane.Audio.HTTPTest do
  use ExUnit.Case, async: false

  alias Backplane.Audio.HTTP

  defmodule MetadataProvider do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> put_resp_header("content-type", "application/json; charset=utf-8")
      |> send_resp(201, String.duplicate("0123456789", 2000))
    end
  end

  defmodule MockProvider do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn, length: 200_000)
      content_length = conn |> get_req_header("content-length") |> List.first()

      cond do
        conn.method != "POST" or conn.request_path != "/v1/speech_to_text" ->
          send_resp(conn, 404, "wrong path")

        content_length != Integer.to_string(byte_size(body)) ->
          send_resp(conn, 400, "wrong length")

        not String.contains?(body, "FILE_BYTES") ->
          send_resp(conn, 400, "missing file")

        not String.contains?(body, ~s(name="response_format"\r\n\r\njson)) ->
          send_resp(conn, 400, "wrong format")

        get_req_header(conn, "language") != ["en"] ->
          send_resp(conn, 400, "wrong language")

        true ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, ~s({"text":"hello"}))
      end
    end
  end

  @tag :stream_response_classification
  test "response-aware receiver gets status and headers with bounded ordered fragments" do
    server = start_supervised!({Bandit, plug: MetadataProvider, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    receiver = fn bytes, %{status: status, headers: headers}, chunks ->
      assert status == 201
      assert {"content-type", "application/json; charset=utf-8"} in headers
      assert byte_size(bytes) <= 16_384
      {:ok, [bytes | chunks]}
    end

    assert {:ok, 201, _, chunks} =
             HTTP.post(
               "http://127.0.0.1:#{port}",
               "/metadata",
               [],
               "",
               System.monotonic_time(:millisecond) + 10_000,
               30_000,
               receiver,
               []
             )

    assert length(chunks) >= 2
    assert IO.iodata_to_binary(Enum.reverse(chunks)) == String.duplicate("0123456789", 2000)
  end

  @tag :tmp_dir
  test "streams multipart file with an exact length and native ASR fields", %{tmp_dir: dir} do
    {:ok, server} = Bandit.start_link(plug: MockProvider, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    path = Path.join(dir, "clip.flac")
    File.write!(path, "FILE_BYTES")
    deadline = System.monotonic_time(:millisecond) + 10_000
    boundary = "test-boundary"

    prefix = [
      "--",
      boundary,
      "\r\ncontent-disposition: form-data; name=\"model\"\r\n\r\nasr-1.0\r\n",
      "--",
      boundary,
      "\r\ncontent-disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n",
      "--",
      boundary,
      "\r\ncontent-disposition: form-data; name=\"file\"; filename=\"clip.flac\"\r\n",
      "content-type: audio/flac\r\n\r\n"
    ]

    suffix = ["\r\n--", boundary, "--\r\n"]

    headers = [
      {"authorization", "Bearer provider-secret"},
      {"content-type", "multipart/form-data; boundary=" <> boundary},
      {"language", "en"}
    ]

    try do
      assert {:ok, 200, _headers, chunks} =
               HTTP.post(
                 "http://127.0.0.1:#{port}",
                 "/v1/speech_to_text",
                 headers,
                 {:file, prefix, path, suffix},
                 deadline,
                 1024,
                 fn bytes, chunks -> {:ok, [bytes | chunks]} end,
                 []
               )

      assert IO.iodata_to_binary(Enum.reverse(chunks)) == ~s({"text":"hello"})
    after
      ThousandIsland.stop(server)
    end
  end
end
