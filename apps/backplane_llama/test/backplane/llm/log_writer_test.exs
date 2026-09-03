defmodule Backplane.LLM.LogWriterTest do
  use Backplane.LLM.ObservabilityCase, async: false

  import Ecto.Query

  alias Backplane.LLM.{LogWriter, ProxyRequest}
  alias Backplane.Observability.Buffer
  alias Backplane.Repo

  @moduletag observability_v2: true

  test "persists sanitized rows with event_id conflict handling", %{} do
    row = %{
      event_id: "evt-dup-test-001",
      operation: "chat_completions",
      outcome: "success",
      requested_model: "gpt-4o",
      status: 200,
      stream: false,
      metadata: %{}
    }

    assert :ok = Buffer.try_enqueue(:llm_proxy, row)
    assert :ok = Buffer.try_enqueue(:llm_proxy, row)
    flush_logs!()

    assert [%ProxyRequest{} = log] =
             Repo.all(from(l in ProxyRequest, where: l.event_id == ^row.event_id))

    assert log.requested_model == "gpt-4o"
    assert log.raw_request == nil
    assert log.raw_response == nil
  end

  test "health reflects buffer and insert totals", %{} do
    assert :ok = Buffer.try_enqueue(:llm_proxy, sample_row("evt-health-001"))
    flush_logs!()

    health = LogWriter.health()
    assert health.status == :ok
    assert health.inserted_total >= 1
    assert is_map(health.buffer)
  end

  test "writer database failure does not crash the process", %{} do
    assert :ok =
             Buffer.try_enqueue(:llm_proxy, %{
               event_id: "evt-bad-provider",
               operation: "messages",
               outcome: "success",
               provider_id: Ecto.UUID.generate(),
               requested_model: "claude",
               status: 200
             })

    flush_logs!()
    health = LogWriter.health()
    assert health.status == :ok
    assert health.failed_total >= 1
  end

  defp sample_row(event_id) do
    %{
      event_id: event_id,
      operation: "messages",
      outcome: "success",
      requested_model: "claude-test",
      status: 200,
      stream: false,
      metadata: %{}
    }
  end
end
