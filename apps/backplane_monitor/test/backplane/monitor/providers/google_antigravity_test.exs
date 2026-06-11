defmodule Backplane.Monitor.Providers.GoogleAntigravityTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Backplane.Monitor.Providers.GoogleAntigravity

  setup do
    previous = Application.get_env(:backplane, :google_antigravity_monitor_req_options)

    Application.put_env(:backplane, :google_antigravity_monitor_req_options,
      plug: {Req.Test, GoogleAntigravity}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane, :google_antigravity_monitor_req_options, previous)
      else
        Application.delete_env(:backplane, :google_antigravity_monitor_req_options)
      end
    end)

    :ok
  end

  test "fetch/2 sends Antigravity OAuth headers and returns normalized credits" do
    Req.Test.stub(GoogleAntigravity, fn conn ->
      assert conn.method == "POST"

      assert conn.request_path ==
               "/google.internal.cloud.code.v1internal.PredictionService/RetrieveUserQuota"

      assert {"authorization", "Bearer google-access"} in conn.req_headers
      assert {"user-agent", "antigravity-cli"} in conn.req_headers
      assert {"accept", "application/grpc"} in conn.req_headers
      assert {"content-type", "application/grpc"} in conn.req_headers

      conn
      |> Plug.Conn.put_resp_content_type("application/grpc")
      |> Plug.Conn.put_resp_header("grpc-status", "0")
      |> Plug.Conn.send_resp(200, grpc_response(quota_response()))
    end)

    assert {:ok, result} =
             GoogleAntigravity.fetch("google-access", %{"project" => "projects/test-project"})

    assert result.provider == "google_ai"
    assert result.status == "ok"

    assert [
             %{
               id: "gemini-2.5-pro",
               label: "Requests",
               available: 42,
               used: nil,
               monthly: nil,
               used_percent: 20,
               reset_time: "2026-06-01T00:00:00Z"
             }
           ] = result.credits

    assert result.links.credits == "https://antigravity.google/g1-credits"
    assert result.links.activity == "https://antigravity.google/g1-activity"
  end

  test "fetch/2 requires a project" do
    assert {:error, :missing_project} = GoogleAntigravity.fetch("google-access", %{})
  end

  test "fetch/2 maps grpc unauthenticated to unauthorized" do
    Req.Test.stub(GoogleAntigravity, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/grpc")
      |> Plug.Conn.put_resp_header("grpc-status", "16")
      |> Plug.Conn.send_resp(200, "")
    end)

    assert {:error, :unauthorized} =
             GoogleAntigravity.fetch("google-access", %{"project" => "projects/test-project"})
  end

  test "normalize_usage_response/1 accepts Cloud Code available credits" do
    raw = %{
      "userTier" => %{
        "availableCredits" => [
          %{"creditType" => "CREDIT_TYPE_PROMPT", "creditAmount" => 800},
          %{"creditType" => "CREDIT_TYPE_FLOW", "creditAmount" => 400},
          %{"creditType" => "CREDIT_TYPE_FCA", "creditAmount" => 90}
        ]
      }
    }

    assert %{
             provider: "google_ai",
             credits: [
               %{id: "prompt", label: "Prompt Credits", available: 800},
               %{id: "flow", label: "Flow Credits", available: 400},
               %{id: "flex", label: "Flex Credits", available: 90}
             ]
           } = GoogleAntigravity.normalize_usage_response(raw)
  end

  test "normalize_usage_response/1 rejects unrecognized bodies" do
    assert {:error, :invalid_usage_response} = GoogleAntigravity.normalize_usage_response(%{})
  end

  defp quota_response do
    field_message(1, quota_bucket())
  end

  defp quota_bucket do
    field_varint(1, 42) <>
      field_message(2, timestamp(1_780_272_000)) <>
      field_varint(3, 1) <>
      field_string(4, "gemini-2.5-pro") <>
      field_float32(5, 0.8)
  end

  defp timestamp(seconds), do: field_varint(1, seconds)

  defp grpc_response(message) do
    <<0, byte_size(message)::unsigned-big-integer-size(32), message::binary>>
  end

  defp field_varint(field, value), do: field_key(field, 0) <> encode_varint(value)

  defp field_string(field, value) do
    encoded = to_string(value)
    field_key(field, 2) <> encode_varint(byte_size(encoded)) <> encoded
  end

  defp field_message(field, message) do
    field_key(field, 2) <> encode_varint(byte_size(message)) <> message
  end

  defp field_float32(field, value) do
    field_key(field, 5) <> <<value::little-float-32>>
  end

  defp field_key(field, wire), do: encode_varint(field <<< 3 ||| wire)

  defp encode_varint(value) when value < 0x80, do: <<value>>

  defp encode_varint(value) do
    <<(value &&& 0x7F) ||| 0x80>> <> encode_varint(value >>> 7)
  end
end
