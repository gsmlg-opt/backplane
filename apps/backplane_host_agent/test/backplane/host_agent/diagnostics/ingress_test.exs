defmodule Backplane.HostAgent.Diagnostics.IngressTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.DiagnosticsClient.{Envelope, Receipt}
  alias Backplane.HostAgent.Diagnostics.{Sources, Spool}
  alias Backplane.HostAgent.HttpRouter

  @moduletag :tmp_dir
  @source "test-source"
  @target "/diagnostics/v1/events"
  @get_status "/diagnostics/v1/status"
  @token "test-generated-diagnostics-token"

  setup %{tmp_dir: dir} do
    System.put_env("BACKPLANE_TEST_DIAGNOSTICS_SOURCE_TOKEN", @token)
    on_exit(fn -> System.delete_env("BACKPLANE_TEST_DIAGNOSTICS_SOURCE_TOKEN") end)

    sources =
      Sources.parse([
        %{
          "id" => @source,
          "application" => "diag-test",
          "token_env" => "BACKPLANE_TEST_DIAGNOSTICS_SOURCE_TOKEN"
        }
      ])

    {:ok, spool} = Spool.start_link(path: Path.join(dir, "events.db"))
    %{state: HttpRouter.init(diagnostics: %{enabled: true, sources: sources}, spool: spool)}
  end

  test "authenticates before reading input and rejects a source forged by an authorized caller",
       %{state: state} do
    assert HttpRouter.call(conn(:post, @target, "unnamed body"), state).status == 401
    assert HttpRouter.call(request(:post, @target, "xyz", "bad-credential"), state).status == 401

    spoof = request(:post, @target, batch("forged")) |> HttpRouter.call(state)
    assert spoof.status == 200

    assert %{
             "receipts" => [
               %{"status" => "permanent_rejection", "reason" => "unauthorized_source"}
             ]
           } = Formata.JSON.decode!(spoof.resp_body)

    valid = request(:post, @target, batch(@source)) |> HttpRouter.call(state)
    assert valid.status == 200

    assert %{"level" => "local_durable", "receipts" => [%{"status" => "stored"}]} =
             Formata.JSON.decode!(valid.resp_body)

    health = request(:get, @get_status, "") |> HttpRouter.call(state)

    assert %{"enabled" => true, "queue" => [%{"state" => "pending", "count" => 1}]} =
             Formata.JSON.decode!(health.resp_body)
  end

  test "returns explicit framing errors under the local transport limit", %{state: state} do
    assert HttpRouter.call(request(:post, @target, "{"), state).status == 400

    assert HttpRouter.call(request(:post, @target, String.duplicate("x", 524_289)), state).status ==
             413
  end

  defp request(method, path, body, token \\ @token) do
    conn(method, path, body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header(Sources.source_header(), @source)
  end

  defp batch(source_id) do
    event = %{
      "schema_version" => 1,
      "event_type" => "exception",
      "event_id" => "event-1",
      "source_id" => source_id,
      "application" => "diag-test",
      "producer_epoch" => "boot",
      "source_sequence" => 1,
      "occurred_at" => "2026-11-28T03:04:05Z",
      "quality" => %{"redaction_policy_version" => 1}
    }

    {:ok, _, digest} = Envelope.seal(event)

    {:ok, bytes} =
      Receipt.encode_batch(Receipt.batch(:local, "batch", [Receipt.entry(event, digest)]))

    bytes
  end
end
