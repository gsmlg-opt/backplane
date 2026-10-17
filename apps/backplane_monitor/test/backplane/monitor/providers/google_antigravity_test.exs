defmodule Backplane.Monitor.Providers.GoogleAntigravityTest do
  use ExUnit.Case, async: false

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

  test "fetch/2 uses the current CLI identity and REST quota summary with all quota groups" do
    Req.Test.stub(GoogleAntigravity, fn conn ->
      assert conn.method == "POST"
      assert {"authorization", "Bearer google-access"} in conn.req_headers

      assert {"user-agent", "antigravity/cli/1.4.0 (aidev_client; os_type=linux; arch=amd64)"} in conn.req_headers

      assert {"content-type", "application/json"} in conn.req_headers

      case conn.request_path do
        "/v1internal:retrieveUserQuotaSummary" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body) == %{"project" => "projects/test-project"}
          Req.Test.json(conn, current_quota_summary())

        "/v1internal:loadCodeAssist" ->
          Req.Test.json(conn, %{"paidTier" => %{"name" => "Google AI Pro"}})
      end
    end)

    assert {:ok, result} =
             GoogleAntigravity.fetch("google-access", %{"project" => "projects/test-project"})

    assert result.plan_type == "Google AI Pro"

    assert [
             %{label: "Gemini Models"},
             %{label: "Claude and GPT models"},
             %{label: "Gemini 4 Argon"}
           ] = result.credits
  end

  test "normalizes current API window names, descriptions, precision and separate Argon quota" do
    assert %{credits: [gemini, third_party, argon]} =
             GoogleAntigravity.normalize_usage_response(current_quota_summary())

    assert gemini.description == "Models within this group: Gemini Flash, Gemini Pro"
    assert [weekly, five_hour] = gemini.buckets
    assert weekly.label == "Weekly Limit Remaining"
    assert weekly.id == "gemini-weekly"
    assert weekly.remaining_fraction == 0.9597
    assert five_hour.label == "Five Hour Limit Remaining"
    assert five_hour.remaining_fraction == 0.859
    assert Enum.map(third_party.buckets, & &1.remaining_fraction) == [1, 1]
    assert Enum.map(third_party.buckets, & &1.label) == ["Weekly Limit", "5-Hour Limit"]
    assert [%{label: "Gemini 4 Argon Weekly Limit", remaining_fraction: 0.8314}] = argon.buckets
    assert argon.description == "For paid Pro plans, Argon quota is separate."
  end

  test "REST authentication and rate limiting errors do not fall back to another API" do
    for {status, expected} <- [{401, :unauthorized}, {429, {:rate_limited, 60}}] do
      Req.Test.stub(GoogleAntigravity, fn conn ->
        assert conn.request_path == "/v1internal:retrieveUserQuotaSummary"
        conn |> Plug.Conn.put_resp_header("retry-after", "60") |> Plug.Conn.send_resp(status, "")
      end)

      assert {:error, ^expected} = GoogleAntigravity.fetch("google-access", %{})
    end
  end

  test "REST discovery falls back to the production endpoint on transport failure" do
    Req.Test.stub(GoogleAntigravity, fn conn ->
      case {conn.host, conn.request_path} do
        {"daily-cloudcode-pa.googleapis.com", "/v1internal:retrieveUserQuotaSummary"} ->
          Plug.Conn.send_resp(conn, 503, "unavailable")

        {"cloudcode-pa.googleapis.com", "/v1internal:retrieveUserQuotaSummary"} ->
          Req.Test.json(conn, current_quota_summary())

        {"cloudcode-pa.googleapis.com", "/v1internal:loadCodeAssist"} ->
          Req.Test.json(conn, %{"paidTier" => %{"name" => "Google AI Pro"}})
      end
    end)

    assert {:ok, %{plan_type: "Google AI Pro", credits: [_, _, _]}} =
             GoogleAntigravity.fetch("google-access", %{"project" => "projects/test-project"})
  end

  test "fetch/2 sends Antigravity OAuth headers and returns normalized credits" do
    Req.Test.stub(GoogleAntigravity, fn conn ->
      assert conn.method == "POST"

      assert conn.request_path ==
               "/google.internal.cloud.code.v1internal.PredictionService/RetrieveUserQuota"

      assert {"authorization", "Bearer google-access"} in conn.req_headers

      assert {"user-agent", "antigravity/cli/1.4.0 (aidev_client; os_type=linux; arch=amd64)"} in conn.req_headers

      assert {"accept", "application/grpc"} in conn.req_headers
      assert {"content-type", "application/grpc"} in conn.req_headers

      conn
      |> Plug.Conn.put_resp_content_type("application/grpc")
      |> Plug.Conn.put_resp_header("grpc-status", "0")
      |> Plug.Conn.send_resp(200, grpc_response(quota_response()))
    end)

    assert {:ok, result} =
             GoogleAntigravity.fetch("google-access", %{
               "project" => "projects/test-project",
               "api_url" =>
                 "https://daily-cloudcode-pa.googleapis.com/google.internal.cloud.code.v1internal.PredictionService/RetrieveUserQuota"
             })

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
    assert {:error, :missing_project} =
             GoogleAntigravity.fetch("google-access", %{"api_url" => "https://example.test/quota"})
  end

  test "fetch/2 maps grpc unauthenticated to unauthorized" do
    Req.Test.stub(GoogleAntigravity, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/grpc")
      |> Plug.Conn.put_resp_header("grpc-status", "16")
      |> Plug.Conn.send_resp(200, "")
    end)

    assert {:error, :unauthorized} =
             GoogleAntigravity.fetch("google-access", %{
               "project" => "projects/test-project",
               "api_url" => "https://example.test/quota"
             })
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

  test "normalize_usage_response/1 accepts retrieveUserQuotaSummary with groups and buckets" do
    raw = %{
      "paidTier" => %{
        "name" => "Google AI Pro",
        "upgradeSubscriptionUri" => "https://one.google.com/explore-plan/ai-pro"
      },
      "groups" => [
        %{
          "displayName" => "Gemini Models",
          "buckets" => [
            %{
              "remainingFraction" => 0.85,
              "resetTime" => "2026-09-11T12:00:00Z",
              "windowDuration" => "604800s"
            },
            %{
              "remainingFraction" => 0.99,
              "resetTime" => "2026-09-04T18:00:00Z",
              "windowDuration" => "18000s"
            }
          ]
        },
        %{
          "displayName" => "Claude and GPT models",
          "buckets" => [
            %{
              "remainingFraction" => 0.45,
              "resetTime" => "2026-09-11T12:00:00Z",
              "windowDuration" => "604800s"
            }
          ]
        }
      ]
    }

    assert %{
             provider: "google_ai",
             plan_type: "Google AI Pro",
             credits: [
               %{
                 id: "gemini-models",
                 label: "Gemini Models",
                 used_percent: 15,
                 remaining_fraction: 0.85,
                 reset_time: "2026-09-04T18:00:00Z",
                 buckets: [
                   %{
                     label: "Weekly Limit",
                     used_percent: 15,
                     remaining_fraction: 0.85,
                     reset_time: "2026-09-11T12:00:00Z"
                   },
                   %{
                     label: "5-Hour Limit",
                     used_percent: 1,
                     remaining_fraction: 0.99,
                     reset_time: "2026-09-04T18:00:00Z"
                   }
                 ]
               },
               %{
                 id: "claude-and-gpt-models",
                 label: "Claude and GPT models",
                 used_percent: 55,
                 remaining_fraction: 0.45,
                 reset_time: "2026-09-11T12:00:00Z",
                 buckets: [
                   %{
                     label: "Weekly Limit",
                     used_percent: 55,
                     remaining_fraction: 0.45,
                     reset_time: "2026-09-11T12:00:00Z"
                   }
                 ]
               }
             ],
             links: %{
               upgrade: "https://one.google.com/explore-plan/ai-pro"
             }
           } = GoogleAntigravity.normalize_usage_response(raw)
  end

  test "normalize_usage_response/1 rejects unrecognized bodies" do
    assert {:error, :invalid_usage_response} = GoogleAntigravity.normalize_usage_response(%{})
  end

  defp current_quota_summary do
    %{
      "groups" => [
        %{
          "displayName" => "Gemini Models",
          "description" => "Models within this group: Gemini Flash, Gemini Pro",
          "buckets" => [
            %{
              "bucketId" => "gemini-weekly",
              "displayName" => "Weekly Limit Remaining",
              "window" => "weekly",
              "remainingFraction" => 0.9597,
              "resetTime" => "2026-10-24T07:10:31Z"
            },
            %{
              "bucketId" => "gemini-5h",
              "displayName" => "Five Hour Limit Remaining",
              "window" => "5h",
              "remainingFraction" => 0.859,
              "resetTime" => "2026-10-17T12:10:31Z"
            }
          ]
        },
        %{
          "displayName" => "Claude and GPT models",
          "buckets" => [
            %{"bucketId" => "3p-weekly", "window" => "weekly", "remainingFraction" => 1},
            %{"bucketId" => "3p-5h", "window" => "5h", "remainingFraction" => 1}
          ]
        },
        %{
          "displayName" => "Gemini 4 Argon",
          "description" => "For paid Pro plans, Argon quota is separate.",
          "buckets" => [
            %{
              "bucketId" => "gemini-argon-wtu-weekly",
              "displayName" => "Gemini 4 Argon Weekly Limit",
              "window" => "weekly",
              "remainingFraction" => 0.8314
            }
          ]
        }
      ]
    }
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
