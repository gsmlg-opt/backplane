defmodule Backplane.Memory.SourceCommandsTest do
  use Backplane.Memory.DataCase, async: false
  alias Backplane.{MemorySpaces, Repo}
  alias Backplane.Memory.{SharedCommands, Memories}

  setup do
    [owner, host] =
      for _ <- 1..2 do
        id = Ecto.UUID.generate()

        Repo.query!(
          "INSERT INTO skill_hosts (id,name,memory_scope,inserted_at,updated_at) VALUES ($1,$2,'source_test',now(),now())",
          [Ecto.UUID.dump!(id), "source-#{id}"]
        )

        id
      end

    {:ok, partition} = MemorySpaces.provision_private_host(owner, "source_shared")
    {:ok, _} = MemorySpaces.provision_private_host(host, "source_private")
    token = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO skill_host_auth_tokens (id,name,token_hash,encrypted_token,inserted_at,updated_at) VALUES ($1,$2,'source-test',$3,now(),now())",
      [Ecto.UUID.dump!(token), token, <<1>>]
    )

    Repo.query!(
      "INSERT INTO skill_host_agent_tokens (id,host_id,auth_token_id,inserted_at,updated_at) VALUES ($1,$2,$3,now(),now())",
      Enum.map([Ecto.UUID.generate(), host, token], &Ecto.UUID.dump!/1)
    )

    auth = %{
      kind: :host_agent,
      host_id: host,
      auth_token_id: token,
      scopes: ~w(host_agent.recall host_agent.import),
      source_client_id: "source-client"
    }

    %{host: host, partition: partition, auth: auth}
  end

  defp command(c, capabilities) do
    operator = %{kind: :trusted_operator, ref: nil, request_id: Ecto.UUID.generate()}

    {:ok, access} =
      MemorySpaces.grant_host_access(operator, c.host, c.partition, capabilities,
        reason: "source test",
        expected_version: 0
      )

    id = Ecto.UUID.generate()

    %{
      "command_id" => id,
      "op" => "source_mutate",
      "access" => %{
        "access_id" => access.access_id,
        "authority_version" => access.authority_version
      },
      "partition" => Map.new(c.partition, fn {key, value} -> {to_string(key), value} end),
      "arguments" => %{
        "protocol" => "memory_sources.v1",
        "event_id" => id,
        "source" => %{
          "integration" => "hermes",
          "installation_id" => Ecto.UUID.generate(),
          "profile_id" => "primary",
          "target" => "memory"
        },
        "entry_id" => Ecto.UUID.generate(),
        "revision" => 1,
        "operation" => "upsert",
        "type" => "semantic",
        "content" => "Canonical source command",
        "occurred_at" => "2026-10-24T01:00:00Z",
        "provenance" => %{"session_id" => "real-session"},
        "agent_id" => "Rikka"
      }
    }
  end

  test "source commands need both existing grants and never invent an authorization tier", c do
    command = command(c, [:remember])
    assert {:error, :unauthorized} = SharedCommands.settle(c.auth, command)
    assert Memories.list([], c.partition) == []
  end

  test "source mutation and source receipt commit atomically with stable canonical replay", c do
    command = command(c, [:remember, :forget])

    assert {:ok, %{status: :committed, canonical_id: id, source_result: result}} =
             SharedCommands.settle(c.auth, command)

    assert result["protocol"] == "memory_sources.v1"
    assert result["event_id"] == command["command_id"]
    assert result["source_revision"] == 1
    assert {:ok, memory} = Memories.public_get(id, c.partition, %{})
    assert memory.agent_id == "Rikka"
    assert memory.host_id == c.host
    assert memory.session_id == "real-session"

    assert {:ok, %{status: :duplicate, canonical_id: ^id, source_result: ^result}} =
             SharedCommands.settle(c.auth, command)

    assert {:error, :idempotency_conflict} =
             SharedCommands.settle(
               c.auth,
               put_in(command, ["arguments", "content"], "changed after lost ACK")
             )

    assert length(Memories.list_evidence(id)) == 1
  end

  test "immutable event identity must match command identity and reject nested trusted fields",
       c do
    command = command(c, [:remember, :forget])

    assert {:error, :invalid_request} =
             SharedCommands.settle(
               c.auth,
               put_in(command, ["arguments", "event_id"], Ecto.UUID.generate())
             )

    assert {:error, :invalid_request} =
             SharedCommands.settle(
               c.auth,
               put_in(command, ["arguments", "provenance", "author"], %{"host_id" => c.host})
             )

    assert Memories.list([], c.partition) == []
  end
end
