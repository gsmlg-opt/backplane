defmodule Backplane.McpProtocol.LoggingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Backplane.McpProtocol.Logging

  defmodule MacroHarness do
    @moduledoc false
    use Logging

    def message(pid, secret) do
      Logging.message(
        evaluated(pid, :message_direction, "incoming"),
        evaluated(pid, :message_type, "request"),
        evaluated(pid, :message_id, 7),
        evaluated(pid, :message_data, %{
          "method" => "tools/call",
          "access_token" => secret,
          "note" => ["Bearer ", secret],
          "char_keyed" => %{~c"token" => secret}
        }),
        evaluated(pid, :message_metadata, level: :error, client_secret: secret)
      )
    end

    def events(pid, secret) do
      Logging.server_event(
        evaluated(pid, :server_event, "authorization"),
        evaluated(pid, :server_details, %{
          authorization_code: secret,
          note: ["Bearer ", secret]
        }),
        evaluated(pid, :server_metadata, level: :error)
      )

      Logging.client_event(
        evaluated(pid, :client_event, "token"),
        evaluated(pid, :client_details, %{refresh_token: secret}),
        evaluated(pid, :client_metadata, level: :error)
      )

      Logging.transport_event(
        evaluated(pid, :transport_event, "Bearer #{secret}"),
        evaluated(pid, :transport_details, %{"Mcp-Param-City" => secret}),
        evaluated(pid, :transport_metadata, level: :error)
      )
    end

    defp evaluated(pid, label, value) do
      send(pid, {:evaluated, label})
      value
    end
  end

  @redacted "[REDACTED]"

  test "log sanitizes the final Logger message and metadata" do
    log =
      capture_log([metadata: :all], fn ->
        Logging.log(
          :error,
          "Authorization: Bearer logger-message-secret",
          access_token: "logger-metadata-secret",
          token: "logger-token-secret"
        )
      end)

    assert log =~ @redacted
    refute log =~ "logger-message-secret"
    refute log =~ "logger-metadata-secret"
    refute log =~ "logger-token-secret"
  end

  test "log sanitizes lazy messages, iodata, and charlists" do
    log =
      capture_log(fn ->
        Logging.log(:error, fn ->
          send(self(), :lazy_message_evaluated)
          "Bearer lazy-secret"
        end)

        Logging.log(:error, ["Bearer ", "iodata-secret"])
        Logging.log(:error, ~c"Bearer charlist-secret")
      end)

    assert_receive :lazy_message_evaluated
    refute_receive :lazy_message_evaluated

    assert log =~ @redacted

    for secret <- ["lazy-secret", "iodata-secret", "charlist-secret"] do
      refute log =~ secret
    end
  end

  test "message macro evaluates arguments once and redacts before inspection" do
    log = capture_log([metadata: :all], fn -> MacroHarness.message(self(), "macro-secret") end)

    for label <- [
          :message_direction,
          :message_type,
          :message_id,
          :message_data,
          :message_metadata
        ] do
      assert_receive {:evaluated, ^label}
    end

    refute_receive {:evaluated, _label}

    assert log =~ "tools/call"
    assert log =~ @redacted
    refute log =~ "macro-secret"
  end

  test "event macros evaluate arguments once and redact event details" do
    log = capture_log([metadata: :all], fn -> MacroHarness.events(self(), "event-secret") end)

    for label <- [
          :server_event,
          :server_details,
          :server_metadata,
          :client_event,
          :client_details,
          :client_metadata,
          :transport_event,
          :transport_details,
          :transport_metadata
        ] do
      assert_receive {:evaluated, ^label}
    end

    refute_receive {:evaluated, _label}

    assert log =~ @redacted
    refute log =~ "event-secret"
  end
end
