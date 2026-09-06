defmodule Backplane.Memory.IngestFixtures do
  alias Backplane.Memory.Ingest.EventValidator
  alias Backplane.MemorySpaces.MemorySpace

  def ingest_auth_context(host_id, overrides \\ %{}) do
    memory_space_id = ensure_memory_space!(host_id)

    partition =
      Map.merge(
        %{
          memory_space_id: memory_space_id,
          host_id: host_id,
          partition_id: "host:#{host_id}",
          scope: "proj_local",
          namespace: "private"
        },
        Map.get(overrides, :partition, %{})
      )

    %{
      host_id: host_id,
      auth_token_id: "token-#{host_id}",
      scopes: ["host_agent.capture"],
      partition: partition
    }
    |> Map.merge(Map.delete(overrides, :partition))
  end

  def memory_space_id(host_id) do
    digest = :crypto.hash(:md5, "test-memory-space:" <> host_id)
    {:ok, memory_space_id} = Ecto.UUID.load(digest)
    memory_space_id
  end

  def ensure_memory_space!(host_id) do
    memory_space_id = memory_space_id(host_id)

    {:ok, _space} =
      %MemorySpace{}
      |> MemorySpace.changeset(%{
        id: memory_space_id,
        kind: "private",
        status: "active"
      })
      |> repo().insert(on_conflict: :nothing)

    memory_space_id
  end

  def valid_event(overrides \\ %{}) do
    payload = Map.get(overrides, "payload", %{"message" => "hello"})

    Map.merge(
      %{
        "event_id" => Ecto.UUID.generate(),
        "schema_version" => 1,
        "host_id" => "host-1",
        "agent_id" => "agent-1",
        "client_id" => "codex-cli",
        "integration" => "codex",
        "project" => "/workspace/backplane",
        "scope" => "project:backplane",
        "session_id" => "session-1",
        "parent_session_id" => nil,
        "sequence" => 1,
        "event_type" => "agent.prompt.submitted",
        "occurred_at" => "2026-08-04T01:00:00.000Z",
        "captured_at" => "2026-08-04T01:00:00.010Z",
        "idempotency_key" => "codex:session-1:1",
        "payload_hash" => EventValidator.payload_hash(payload),
        "privacy" => %{"filtered" => true, "filter_version" => "1"},
        "trace" => %{"correlation_id" => "correlation-1"},
        "payload" => payload
      },
      overrides
    )
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
