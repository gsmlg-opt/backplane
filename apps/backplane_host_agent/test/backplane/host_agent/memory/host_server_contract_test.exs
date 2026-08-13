defmodule Backplane.HostAgent.Memory.HostServerContractTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.Hooks.ClaudeCode
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool
  alias Backplane.Memory.Ingest.EventValidator

  @moduletag :tmp_dir

  test "a normalized and spooled hook satisfies the server envelope contract", %{tmp_dir: dir} do
    spool =
      start_supervised!(
        {Spool,
         database: Path.join(dir, "capture.db"),
         name: nil,
         id: {:host_server_contract_spool, System.unique_integer([:positive])}}
      )

    source = %{
      "session_id" => "session-1",
      "source_event_id" => "prompt-1",
      "occurred_at" => "2026-08-04T01:00:00Z",
      "cwd" => "/workspace/backplane",
      "prompt" => "keep this"
    }

    assert {:ok, normalized} =
             ClaudeCode.normalize("UserPromptSubmit", source, %{host_id: "trusted-host"})

    assert {:ok, _envelope} = Spool.append(spool, normalized)
    assert [wire_envelope] = Spool.next_batch(spool, 1, 524_288)
    assert {:ok, validated} = EventValidator.validate(wire_envelope)
    assert validated["event_id"] == normalized.event_id
  end
end
