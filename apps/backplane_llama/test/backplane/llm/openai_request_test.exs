defmodule Backplane.LLM.OpenAI.RequestTest do
  use ExUnit.Case, async: true
  alias Backplane.LLM.OpenAI.Request

  test "same-model JSON preserves original bytes and unknown fields" do
    body = "{\n  \"model\": \"image-model\", \"future\": [1, true] }"
    assert {:ok, request} = Request.parse(body, ["application/json"])
    assert Request.rewrite(request, :images, "image-model") == body
  end

  test "duplicate JSON routing fields and nested session fields are rejected" do
    for body <- [~s({"model":"one","model":"two"}), ~s({"session":{"model":"one","model":"two"}})] do
      assert {:error, :invalid_json} = Request.parse(body, ["application/json"])
    end
  end

  test "multipart model rewrite preserves exact trailing bytes and binary payloads" do
    body =
      ~s|--test\r\nContent-Disposition: form-data; name="model"\r\n\r\nprovider/image\r\n--test\r\nContent-Disposition: form-data; name="image[]"; filename="x.png"\r\nContent-Type: image/png\r\n\r\n| <>
        <<255, 0, 128>> <> "\r\n--test--"

    assert {:ok, request} = Request.parse(body, ["multipart/form-data; boundary=test"])

    assert Request.rewrite(request, :images, "image") ==
             :binary.replace(body, "provider/image", "image")
  end

  test "missing image model is inserted as an ordinary multipart field" do
    body =
      "--test\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nhello\r\n--test--\r\n"

    assert {:ok, request} = Request.parse(body, ["multipart/form-data; boundary=test"])
    rewritten = Request.rewrite(request, :images, "default-image")
    assert {:ok, parsed} = Request.parse(rewritten, ["multipart/form-data; boundary=test"])
    assert {:ok, "default-image"} = Request.model(parsed, :images)
  end

  test "Realtime client-secret nested model and call session JSON are rewritten separately" do
    assert {:ok, request} =
             Request.parse(
               ~s({"session":{"type":"realtime","model":"provider/voice","audio":{"input":{}}},"expires_after":{"anchor":"created_at","seconds":60}}),
               ["application/json"]
             )

    assert {:ok, "provider/voice"} = Request.model(request, :realtime)
    rewritten = Request.rewrite(request, :realtime, "voice") |> Jason.decode!()
    assert rewritten["session"]["model"] == "voice"
    assert rewritten["expires_after"]["seconds"] == 60

    body =
      "--test\r\nContent-Disposition: form-data; name=\"session\"\r\n\r\n{\"type\":\"realtime\",\"model\":\"provider/voice\"}\r\n--test\r\nContent-Disposition: form-data; name=\"sdp\"\r\n\r\nv=0\r\n--test--\r\n"

    assert {:ok, request} = Request.parse(body, ["multipart/form-data; boundary=test"])
    assert {:ok, "provider/voice"} = Request.model(request, :realtime)

    assert {:ok, parsed} =
             Request.parse(Request.rewrite(request, :realtime, "voice"), [
               "multipart/form-data; boundary=test"
             ])

    assert {:ok, "voice"} = Request.model(parsed, :realtime)
    assert Enum.find(parsed.parts, &(&1.name == "sdp")).data == "v=0"
  end

  test "malformed multipart and duplicate routing parts fail explicitly" do
    assert {:error, :malformed_multipart} =
             Request.parse("not multipart", ["multipart/form-data; boundary=test"])

    body =
      "--test\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\none\r\n--test\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ntwo\r\n--test--\r\n"

    assert {:ok, request} = Request.parse(body, ["multipart/form-data; boundary=test"])
    assert {:error, :duplicate_model} = Request.model(request, :images)
    assert {:error, :duplicate_parameter} = Request.audio_params(request)
  end
end
