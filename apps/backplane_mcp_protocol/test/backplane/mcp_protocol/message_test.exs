defmodule Backplane.McpProtocol.MessageTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Message

  describe "decode/1" do
    test "decodes newline-delimited JSON-RPC messages" do
      input =
        [
          ~s({"jsonrpc":"2.0","method":"ping","id":1}),
          ~s({"jsonrpc":"2.0","method":"notifications/initialized"})
        ]
        |> Enum.join("\n")

      assert {:ok, [request, notification]} = Message.decode(input <> "\n")
      assert request["method"] == "ping"
      assert request["id"] == 1
      assert notification["method"] == "notifications/initialized"
    end

    test "returns an error for bad JSON or invalid protocol shape" do
      assert {:error, %Jason.DecodeError{}} =
               Message.decode(~s({"jsonrpc":"2.0","method":broken}\n))

      assert {:error, :invalid_message} =
               Message.decode(~s({"jsonrpc":"2.0","method":"unknown/method","id":1}\n))
    end
  end

  describe "validate_message/1" do
    test "accepts common request, notification, response, and error messages" do
      assert {:ok, _} =
               Message.validate_message(%{
                 "jsonrpc" => "2.0",
                 "method" => "initialize",
                 "id" => 1,
                 "params" => %{
                   "protocolVersion" => "2025-11-25",
                   "capabilities" => %{},
                   "clientInfo" => %{"name" => "client", "version" => "1.0.0"}
                 }
               })

      assert {:ok, _} =
               Message.validate_message(%{
                 "jsonrpc" => "2.0",
                 "method" => "tools/list",
                 "id" => 2
               })

      assert {:ok, _} =
               Message.validate_message(%{
                 "jsonrpc" => "2.0",
                 "method" => "notifications/progress",
                 "params" => %{"progressToken" => "p", "progress" => 1}
               })

      assert {:ok, _} =
               Message.validate_message(%{"jsonrpc" => "2.0", "result" => %{}, "id" => 3})

      assert {:ok, _} =
               Message.validate_message(%{
                 "jsonrpc" => "2.0",
                 "error" => %{"code" => -32_600, "message" => "Invalid Request"},
                 "id" => nil
               })
    end

    test "rejects invalid method names and missing initialize fields" do
      assert {:error, :invalid_message} =
               Message.validate_message(%{"jsonrpc" => "2.0", "method" => "nope", "id" => 1})

      assert {:error, :invalid_message} =
               Message.validate_message(%{
                 "jsonrpc" => "2.0",
                 "method" => "initialize",
                 "id" => 1,
                 "params" => %{"clientInfo" => %{"name" => "client", "version" => "1.0.0"}}
               })
    end
  end

  describe "encoding" do
    test "encodes requests and notifications with JSON-RPC metadata" do
      assert {:ok, request_json} = Message.encode_request(%{"method" => "ping"}, "req-1")
      assert String.ends_with?(request_json, "\n")

      assert %{"jsonrpc" => "2.0", "method" => "ping", "id" => "req-1"} =
               Jason.decode!(request_json)

      assert {:ok, notification_json} =
               Message.encode_notification(%{"method" => "notifications/initialized"})

      decoded = Jason.decode!(notification_json)
      assert decoded["jsonrpc"] == "2.0"
      refute Map.has_key?(decoded, "id")
    end

    test "rejects invalid outbound requests and notifications" do
      assert {:error, :invalid_message} = Message.encode_request(%{"method" => "unknown"}, 1)
      assert {:error, :invalid_message} = Message.encode_notification(%{"method" => "unknown"})
    end
  end

  describe "classification" do
    test "classifies JSON-RPC message types" do
      assert Message.request?(%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1})
      assert Message.notification?(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      assert Message.response?(%{"jsonrpc" => "2.0", "result" => %{}, "id" => 1})

      assert Message.error?(%{
               "jsonrpc" => "2.0",
               "error" => %{"code" => -1, "message" => "x"},
               "id" => 1
             })
    end
  end

  describe "notification helpers" do
    test "encodes progress and log notifications" do
      assert {:ok, progress_json} =
               Message.encode_progress_notification(%{
                 "progressToken" => "progress-1",
                 "progress" => 5,
                 "total" => 10
               })

      assert %{
               "method" => "notifications/progress",
               "params" => %{"progressToken" => "progress-1", "progress" => 5, "total" => 10}
             } = Jason.decode!(progress_json)

      assert {:ok, log_json} = Message.encode_log_message("warning", "slow call", "hub")

      assert %{
               "method" => "notifications/message",
               "params" => %{"level" => "warning", "data" => "slow call", "logger" => "hub"}
             } = Jason.decode!(log_json)
    end
  end
end
