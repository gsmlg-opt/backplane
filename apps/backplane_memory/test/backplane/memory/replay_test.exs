defmodule Backplane.Memory.ReplayTest do
  use Backplane.Memory.DataCase, async: false
  alias Backplane.Memory.Replay
  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Projections.Rebuild

  @partition %{
    host_id: "replay-host",
    client_id: "replay-client",
    scope: "replay-scope",
    namespace: "private"
  }

  test "loads the current immutable projection through a bounded exact-partition cursor" do
    session = "replay-#{System.unique_integer([:positive])}"
    append!(session, 1, "agent.session.started", %{})
    append!(session, 2, "agent.prompt.submitted", %{"source" => %{"prompt" => "hello"}})
    append!(session, 3, "conversation.agent_message", %{"source" => %{"message" => "answer"}})
    assert {:ok, _} = Rebuild.session(@partition.host_id, session)

    assert {:ok, %{events: [first, second], next_cursor: cursor}} =
             Replay.load(@partition, session, limit: 2)

    assert [first.kind, second.kind] == ["session_boundary", "prompt"]
    assert is_binary(cursor)

    assert Map.keys(first.links) |> Enum.sort() == [
             :action,
             :crystal,
             :graph,
             :lesson,
             :memory,
             :summary
           ]

    assert {:ok, %{events: [%{kind: "assistant_response"}], next_cursor: nil}} =
             Replay.load(@partition, session, cursor: cursor, limit: 2)

    append!(session, 4, "agent.session.ended", %{})
    assert {:ok, _} = Rebuild.session(@partition.host_id, session)
    assert {:error, :invalid_cursor} = Replay.load(@partition, session, cursor: cursor, limit: 2)

    assert {:error, :not_found} =
             Replay.load(Map.put(@partition, :host_id, "foreign"), session)

    for key <- [:client_id, :scope, :namespace] do
      assert {:error, :not_found} =
               Replay.load(Map.put(@partition, key, "foreign"), session)
    end

    assert {:error, :invalid_options} = Replay.load(@partition, session, limit: 101)
    assert {:error, :invalid_options} = Replay.load(@partition, session, unknown: true)
    assert {:error, :invalid_cursor} = Replay.load(@partition, session, cursor: "not-base64")

    assert {:error, :unauthorized} =
             Replay.load(Map.delete(@partition, :namespace), session)
  end

  test "persisted structured tool detail redacts sensitive keys and values" do
    session = "replay-private-#{System.unique_integer([:positive])}"

    append!(session, 1, "tool.call.started", %{
      "source" => %{
        "tool_name" => "HTTP",
        "input" => %{"token" => "short-secret", "url" => "https://example.test"}
      }
    })

    assert {:ok, _result} = Rebuild.session(@partition.host_id, session)
    assert {:ok, %{events: [%{detail: detail}]}} = Replay.load(@partition, session)
    assert detail["tool_input"]["token"] == "[REDACTED]"
    refute inspect(detail) =~ "short-secret"
  end

  defp append!(session, sequence, type, payload) do
    assert {:ok, {:inserted, _}} =
             Store.append_tagged(%{
               id: Ecto.UUID.generate(),
               stream_id: "capture:#{@partition.host_id}:#{session}",
               host_id: @partition.host_id,
               client_id: @partition.client_id,
               scope: @partition.scope,
               namespace: @partition.namespace,
               session_id: session,
               sequence: sequence,
               source_sequence: sequence,
               event_type: type,
               occurred_at: DateTime.add(~U[2026-08-12 00:00:00.000000Z], sequence),
               idempotency_key: "#{session}:#{sequence}",
               payload: payload,
               payload_hash: "sha256:#{session}:#{sequence}",
               schema_version: 1
             })
  end
end
