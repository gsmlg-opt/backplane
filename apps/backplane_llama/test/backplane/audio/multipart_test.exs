defmodule Backplane.Audio.MultipartTest do
  use ExUnit.Case, async: true

  alias Backplane.Audio.Multipart

  @moduletag :tmp_dir

  test "pins the MiniMax transcription byte layout, headers and content length", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "upload.raw")
    audio = <<0, 1, 2, 255>> <> String.duplicate("a", 40_000)
    File.write!(path, audio)

    multipart =
      Multipart.encode(
        [
          {"model", "speech-model"},
          {"response_format", "json"},
          {"file",
           {File.stream!(path, 32_768), filename: "audio.mp3", content_type: "audio/mpeg"}}
        ],
        boundary: "test-boundary"
      )

    expected =
      "--test-boundary\r\n" <>
        "content-disposition: form-data; name=\"model\"\r\n\r\n" <>
        "speech-model\r\n" <>
        "--test-boundary\r\n" <>
        "content-disposition: form-data; name=\"response_format\"\r\n\r\n" <>
        "json\r\n" <>
        "--test-boundary\r\n" <>
        ~s|content-disposition: form-data; name="file"; filename="audio.mp3"\r\n| <>
        "content-type: audio/mpeg\r\n\r\n" <>
        audio <>
        "\r\n" <>
        "--test-boundary--\r\n"

    assert multipart.content_type == "multipart/form-data; boundary=test-boundary"
    assert multipart.size == byte_size(expected)
    assert multipart.body |> Enum.to_list() |> IO.iodata_to_binary() == expected
  end

  test "keeps in-memory bodies as iodata and escapes quotes, CR and LF in parameters" do
    multipart =
      Multipart.encode(
        [
          {:count, 7},
          {"na\"me", {"value", filename: "a\r\nb.txt", content_type: "text/plain"}}
        ],
        boundary: "b"
      )

    expected =
      "--b\r\ncontent-disposition: form-data; name=\"count\"\r\n\r\n7\r\n" <>
        ~s|--b\r\ncontent-disposition: form-data; name="na%22me"; filename="a%0D%0Ab.txt"\r\n| <>
        "content-type: text/plain\r\n\r\nvalue\r\n--b--\r\n"

    assert is_list(multipart.body)
    assert IO.iodata_to_binary(multipart.body) == expected
    assert multipart.size == byte_size(expected)
  end

  test "generates a random lowercase hex boundary by default" do
    %{content_type: "multipart/form-data; boundary=" <> boundary} = Multipart.encode([{"a", "b"}])
    assert boundary =~ ~r/\A[0-9a-f]{32}\z/
  end
end
