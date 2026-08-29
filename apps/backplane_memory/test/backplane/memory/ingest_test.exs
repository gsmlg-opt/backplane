defmodule Backplane.Memory.IngestTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query

  alias Backplane.Memory.Events.{Event, Stream}
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Ingest.EventValidator
  import Backplane.Memory.IngestFixtures

  test "100 sequential authenticated deliveries create one durable captured-event effect" do
    event = valid_event()
    batch = %{"batch_id" => Ecto.UUID.generate(), "host_id" => "host-1", "events" => [event]}
    auth = auth_context("host-1")

    results =
      Enum.map(1..100, fn _delivery ->
        assert {:ok, %{"results" => [result]}} = Ingest.ingest_batch(auth, batch)
        result
      end)

    assert [%{"status" => "accepted", "server_event_id" => server_event_id} | duplicates] =
             results

    assert Enum.all?(duplicates, &(&1["status"] == "duplicate"))
    assert [^server_event_id] = results |> Enum.map(& &1["server_event_id"]) |> Enum.uniq()

    assert [
             %Event{
               id: ^server_event_id,
               host_id: "host-1",
               idempotency_key: "capture:6:host-1:codex:session-1:1",
               raw_envelope: %{"idempotency_key" => "codex:session-1:1"}
             }
           ] =
             repo().all(
               from(e in Event,
                 where:
                   e.host_id == "host-1" and
                     e.idempotency_key == "capture:6:host-1:codex:session-1:1"
               )
             )
  end

  test "persists accepted events, returns exact duplicates, and rejects identity conflicts" do
    event = valid_event()
    batch = %{"batch_id" => Ecto.UUID.generate(), "host_id" => "host-1", "events" => [event]}

    assert {:ok, %{"results" => [%{"status" => "accepted", "server_event_id" => id}]}} =
             Ingest.ingest_batch(auth_context("host-1"), batch)

    assert {:ok, %{"results" => [%{"status" => "duplicate", "server_event_id" => ^id}]}} =
             Ingest.ingest_batch(auth_context("host-1"), batch)

    assert repo().aggregate(from(e in Event, where: e.id == ^id), :count) == 1

    changed =
      event
      |> Map.put("integration", "changed-integration")

    assert {:ok, %{"results" => [result]}} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => batch["batch_id"],
               "host_id" => "host-1",
               "events" => [changed]
             })

    assert result["status"] == "rejected"
    assert result["retryable"] == false
    assert result["reason"] == "identity_conflict"

    changed_payload = %{"message" => "changed"}

    changed =
      event
      |> Map.put("payload", changed_payload)
      |> Map.put("payload_hash", EventValidator.payload_hash(changed_payload))

    assert {:ok, %{"results" => [result]}} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => batch["batch_id"],
               "host_id" => "host-1",
               "events" => [changed]
             })

    assert result["status"] == "rejected"
    assert result["reason"] == "identity_conflict"

    changed_key = Map.put(event, "idempotency_key", "different-key")

    assert {:ok, %{"results" => [result]}} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => batch["batch_id"],
               "host_id" => "host-1",
               "events" => [changed_key]
             })

    assert result["status"] == "rejected"
    assert result["reason"] == "identity_conflict"

    cross_host =
      event
      |> Map.put("host_id", "host-2")
      |> Map.put("idempotency_key", "host-2-key")

    assert {:ok, %{"results" => [result]}} =
             Ingest.ingest_batch(auth_context("host-2"), %{
               "batch_id" => batch["batch_id"],
               "host_id" => "host-2",
               "events" => [cross_host]
             })

    assert result["status"] == "rejected"
    assert result["reason"] == "identity_conflict"
  end

  test "processes mixed outcomes independently and preserves input order" do
    accepted = valid_event()
    future = valid_event(%{"schema_version" => 2})
    spoofed = valid_event(%{"host_id" => "host-2"})
    authority_claim = valid_event(%{"partition_id" => "host:host-1"})
    malformed = valid_event() |> Map.put("event_id", "bad")

    assert {:ok, %{"batch_id" => "batch-1", "results" => results}} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => "batch-1",
               "host_id" => "host-1",
               "events" => [accepted, future, spoofed, authority_claim, malformed]
             })

    assert Enum.map(results, & &1["status"]) == [
             "accepted",
             "rejected",
             "rejected",
             "rejected",
             "rejected"
           ]

    assert Enum.at(results, 1)["reason"] == "unsupported_schema"
    assert Enum.at(results, 2)["reason"] == "partition_mismatch"
    assert Enum.at(results, 3)["reason"] == "partition_mismatch"
    assert Enum.at(results, 4)["reason"] == "invalid_event"
    assert Enum.all?(Enum.drop(results, 1), &(&1["retryable"] == false))
  end

  test "server-side privacy filtering persists only sanitized raw envelope and recomputed hash" do
    raw_secret = "server-side-secret"
    payload = %{"password" => raw_secret, "token_count" => 42}
    event = valid_event(%{"payload" => payload})

    assert {:ok, %{"results" => [%{"status" => "accepted", "server_event_id" => id}]}} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => "privacy",
               "host_id" => "host-1",
               "events" => [event]
             })

    stored = repo().get!(Event, id)
    encoded = Jason.encode!(stored.raw_envelope)
    refute encoded =~ raw_secret
    assert stored.payload["password"] == "[REDACTED]"
    assert stored.payload["token_count"] == 42
    assert stored.payload_hash == EventValidator.payload_hash(stored.raw_envelope["payload"])
    assert stored.raw_envelope["payload_hash"] == stored.payload_hash
  end

  test "storage failures are retryable and transaction rollback is never accepted" do
    event = valid_event()

    assert {:ok, %{"results" => [result]}} =
             Ingest.ingest_batch(
               auth_context("host-1"),
               %{
                 "batch_id" => "failure",
                 "host_id" => "host-1",
                 "events" => [event]
               },
               store: Backplane.Memory.IngestTest.RollbackStore
             )

    assert result["status"] == "failed"
    assert result["retryable"] == true
    assert result["reason"] == "transaction_rolled_back"
  end

  test "accepts out-of-order source sequences without using them as the server cursor" do
    first = valid_event(%{"sequence" => 42, "idempotency_key" => "source:42"})

    second =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "sequence" => 7,
        "idempotency_key" => "source:7"
      })

    assert {:ok, %{"results" => results}} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => "out-of-order",
               "host_id" => "host-1",
               "events" => [first, second]
             })

    assert Enum.map(results, & &1["status"]) == ["accepted", "accepted"]

    stored =
      results
      |> Enum.map(&repo().get!(Event, &1["server_event_id"]))

    assert Enum.map(stored, & &1.sequence) == [1, 2]
    assert Enum.map(stored, & &1.source_sequence) == [42, 7]
  end

  test "privacy-invalid payloads are permanently rejected as malformed" do
    payload = %{"invalid" => <<255>>}
    event = valid_event() |> Map.put("payload", payload)

    assert {:ok, %{"results" => [result]}} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => "invalid-privacy",
               "host_id" => "host-1",
               "events" => [event]
             })

    assert result["status"] == "rejected"
    assert result["retryable"] == false
    assert result["reason"] == "invalid_event"
  end

  test "programmer errors are not mislabeled as transient database failures" do
    event = valid_event()

    assert_raise RuntimeError, "programmer bug", fn ->
      Ingest.ingest_batch(
        auth_context("host-1"),
        %{"batch_id" => "bug", "host_id" => "host-1", "events" => [event]},
        store: Backplane.Memory.IngestTest.BuggyStore
      )
    end
  end

  test "requires the batch host and binds it to the authenticated host" do
    event = valid_event()

    assert {:error, :invalid_batch} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => "missing-host",
               "events" => [event]
             })

    assert {:error, :host_mismatch} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => "wrong-host",
               "host_id" => "host-2",
               "events" => [event]
             })

    assert {:error, :invalid_batch} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => "improper-events",
               "host_id" => "host-1",
               "events" => [event | :not_a_list]
             })
  end

  test "requires explicit capture authorization from an authenticated token" do
    batch = %{
      "batch_id" => "unauthorized",
      "host_id" => "host-1",
      "events" => [valid_event()]
    }

    for auth_context <- [
          %{host_id: "host-1", auth_token_id: "token-1"},
          %{host_id: "host-1", auth_token_id: "token-1", capture_authorized: false},
          %{host_id: "host-1", scopes: ["host_agent.capture"]}
        ] do
      assert {:error, :capture_unauthorized} =
               Ingest.ingest_batch(auth_context, batch,
                 store: Backplane.Memory.IngestTest.BuggyStore
               )
    end
  end

  test "binds canonical authority to the trusted partition and retains filtered provenance" do
    event =
      valid_event(%{
        "agent_id" => "host-attested-agent",
        "client_id" => "spoofed-client password=do-not-store",
        "scope" => "project:host-attested-scope token=do-not-store"
      })

    assert {:ok, %{"results" => [%{"status" => "accepted", "server_event_id" => id}]}} =
             Ingest.ingest_batch(auth_context("host-1", %{auth_token_id: "trusted-token"}), %{
               "batch_id" => "trusted-client",
               "host_id" => "host-1",
               "events" => [event]
             })

    stored = repo().get!(Event, id)
    assert stored.client_id == "host:host-1"
    assert stored.raw_envelope["client_id"] == "host:host-1"
    assert stored.scope == "proj_local"
    assert stored.raw_envelope["scope"] == "proj_local"
    assert stored.raw_envelope["namespace"] == "private"
    assert stored.raw_envelope["source_client_id"] == "spoofed-client [REDACTED]"
    assert stored.raw_envelope["source_scope"] == "project:host-attested-scope [REDACTED]"
    assert stored.ingest_auth_token_id == "trusted-token"
    assert stored.agent_id == "host-attested-agent"
  end

  test "omitted source authority persists only the authenticated canonical partition" do
    event = valid_event() |> Map.delete("client_id") |> Map.delete("scope")

    assert {:ok, %{"results" => [%{"status" => "accepted", "server_event_id" => id}]}} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => "omitted-source-authority",
               "host_id" => "host-1",
               "events" => [event]
             })

    stored = repo().get!(Event, id)
    assert stored.client_id == "host:host-1"
    assert stored.scope == "proj_local"
    refute Map.has_key?(stored.raw_envelope, "source_client_id")
    refute Map.has_key?(stored.raw_envelope, "source_scope")
  end

  test "accepts a normalized Claude Code hook project scope as provenance under the host scope" do
    cwd = "/home/gao/Workspace/gsmlg-opt/backplane"
    occurred_at = "2026-08-04T01:00:00.000Z"

    payload = %{
      "hook" => "user-prompt-submit",
      "source" => %{
        "session_id" => "session-1",
        "agent_id" => "claude-main",
        "source_event_id" => "source-user-prompt-submit",
        "occurred_at" => occurred_at,
        "cwd" => cwd,
        "prompt" => "implement the capture boundary"
      }
    }

    event =
      valid_event(%{
        "agent_id" => "claude-main",
        "client_id" => "claude_code",
        "integration" => "claude_code",
        "project" => cwd,
        "scope" => "project:#{cwd}",
        "event_type" => "agent.prompt.submitted",
        "occurred_at" => occurred_at,
        "idempotency_key" =>
          "claude_code:session-1:user-prompt-submit:" <> String.duplicate("a", 64),
        "privacy" => %{
          "filtered" => false,
          "filter_version" => "pending",
          "redaction_count" => 0,
          "private_blocks_removed" => 0
        },
        "trace" => %{},
        "payload" => payload
      })

    event = Map.put(event, "payload_hash", EventValidator.payload_hash(payload))

    assert {:ok, %{"results" => [%{"status" => "accepted", "server_event_id" => id}]}} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => "claude-hook-project-scope",
               "host_id" => "host-1",
               "events" => [event]
             })

    stored = repo().get!(Event, id)
    assert stored.integration == "claude_code"
    assert stored.scope == "proj_local"
    assert stored.raw_envelope["source_scope"] == "project:#{cwd}"
    assert stored.payload["hook"] == "user-prompt-submit"
    assert stored.payload["source"]["cwd"] == cwd
  end

  test "rejects explicit v1 authority fields before persistence" do
    for authority_key <- ~w(memory_space_id partition_id namespace) do
      event = valid_event(%{authority_key => "attacker-selected"})

      assert {:ok, %{"results" => [result]}} =
               Ingest.ingest_batch(auth_context("host-1"), %{
                 "batch_id" => "authority-#{authority_key}",
                 "host_id" => "host-1",
                 "events" => [event]
               })

      assert result == %{
               "event_id" => event["event_id"],
               "status" => "rejected",
               "retryable" => false,
               "reason" => "partition_mismatch"
             }
    end

    assert repo().aggregate(Event, :count) == 0
  end

  test "accepts atom-only and matching dual host claims" do
    atom_only =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "idempotency_key" => "atom-only-host"
      })
      |> Map.delete("host_id")
      |> Map.put(:host_id, "host-1")

    matching_dual =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "sequence" => 2,
        "idempotency_key" => "matching-dual-host"
      })
      |> Map.put(:host_id, "host-1")

    assert {:ok, %{"results" => results}} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => "compatible-host-claims",
               "host_id" => "host-1",
               "events" => [atom_only, matching_dual]
             })

    assert Enum.map(results, & &1["status"]) == ["accepted", "accepted"]

    for result <- results do
      stored = repo().get!(Event, result["server_event_id"])
      assert stored.host_id == "host-1"
      assert stored.raw_envelope["host_id"] == "host-1"
      refute Map.has_key?(stored.raw_envelope, :host_id)
    end
  end

  test "rejects every conflicting dual host claim before spoofed provenance persists" do
    atom_trusted_string_spoofed =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "host_id" => "host-spoofed-string",
        "idempotency_key" => "atom-trusted-string-spoofed"
      })
      |> Map.put(:host_id, "host-1")

    string_trusted_atom_spoofed =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "idempotency_key" => "string-trusted-atom-spoofed"
      })
      |> Map.put(:host_id, "host-spoofed-atom")

    assert {:ok, %{"results" => results}} =
             Ingest.ingest_batch(auth_context("host-1"), %{
               "batch_id" => "conflicting-host-claims",
               "host_id" => "host-1",
               "events" => [atom_trusted_string_spoofed, string_trusted_atom_spoofed]
             })

    assert Enum.map(results, &Map.take(&1, ["status", "retryable", "reason"])) == [
             %{
               "status" => "rejected",
               "retryable" => false,
               "reason" => "partition_mismatch"
             },
             %{
               "status" => "rejected",
               "retryable" => false,
               "reason" => "partition_mismatch"
             }
           ]

    assert repo().aggregate(Event, :count) == 0
  end

  test "missing or malformed trusted partitions cannot produce accepted events" do
    event = valid_event()

    invalid_auth_contexts = [
      Map.delete(auth_context("host-1"), :partition),
      auth_context("host-1", %{partition: nil}),
      auth_context("host-1", %{partition: %{}}),
      auth_context("host-1", %{partition: trusted_partition("host-2")}),
      auth_context("host-1", %{
        partition: %{trusted_partition("host-1") | partition_id: "host:other"}
      }),
      auth_context("host-1", %{
        partition: %{trusted_partition("host-1") | scope: ""}
      }),
      auth_context("host-1", %{
        partition: %{trusted_partition("host-1") | namespace: "shared"}
      })
    ]

    for {auth, index} <- Enum.with_index(invalid_auth_contexts) do
      assert {:ok, %{"results" => [result]}} =
               Ingest.ingest_batch(
                 auth,
                 %{
                   "batch_id" => "invalid-partition-#{index}",
                   "host_id" => "host-1",
                   "events" => [event]
                 },
                 store: Backplane.Memory.IngestTest.BuggyStore
               )

      assert result == %{
               "event_id" => event["event_id"],
               "status" => "rejected",
               "retryable" => false,
               "reason" => "invalid_partition"
             }
    end
  end

  test "permanent Store errors are rejected while known rollback errors remain retryable" do
    event = valid_event()
    batch = %{"batch_id" => "classification", "host_id" => "host-1", "events" => [event]}

    assert {:ok, %{"results" => [%{"status" => "rejected", "reason" => "stream_closed"}]}} =
             Ingest.ingest_batch(auth_context("host-1"), batch,
               store: Backplane.Memory.IngestTest.ClosedStore
             )

    assert {:ok, %{"results" => [%{"status" => "rejected", "reason" => "invalid_event"}]}} =
             Ingest.ingest_batch(auth_context("host-1"), batch,
               store: Backplane.Memory.IngestTest.InvalidStore
             )

    assert {:ok, %{"results" => [%{"status" => "failed", "retryable" => true}]}} =
             Ingest.ingest_batch(auth_context("host-1"), batch,
               store: Backplane.Memory.IngestTest.RollbackStore
             )
  end

  test "source identity conflicts are permanently rejected" do
    first = valid_event()

    second =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "idempotency_key" => "same-source-different-event"
      })

    batch = %{"batch_id" => "source-identity", "host_id" => "host-1", "events" => [first]}

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(auth_context("host-1"), batch)

    assert {:ok, %{"results" => [result]}} =
             Ingest.ingest_batch(auth_context("host-1"), %{batch | "events" => [second]})

    assert result["status"] == "rejected"
    assert result["retryable"] == false
    assert result["reason"] == "identity_conflict"
  end

  test "authenticated project conflicts are permanent per-event rejections with partial ACK" do
    auth = auth_context("host-1")

    project_a =
      valid_event(%{
        "project" => "project-a",
        "idempotency_key" => "stream-project:first"
      })

    project_b =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "project" => "project-b",
        "sequence" => 2,
        "idempotency_key" => "stream-project:conflict"
      })

    compatible_a =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "project" => "project-a",
        "sequence" => 3,
        "idempotency_key" => "stream-project:compatible"
      })

    assert {:ok, %{"results" => [%{"status" => "accepted", "server_event_id" => first_id}]}} =
             Ingest.ingest_batch(auth, %{
               "batch_id" => "stream-project-first",
               "host_id" => "host-1",
               "events" => [project_a]
             })

    first = repo().get!(Event, first_id)
    original_stream = repo().get!(Stream, first.stream_id)

    assert {:ok,
            %{
              "results" => [
                %{
                  "status" => "rejected",
                  "retryable" => false,
                  "reason" => "stream_metadata_conflict"
                }
              ]
            }} =
             Ingest.ingest_batch(auth, %{
               "batch_id" => "stream-project-conflict",
               "host_id" => "host-1",
               "events" => [project_b]
             })

    assert repo().get!(Event, first_id) == first
    assert repo().get!(Stream, first.stream_id) == original_stream

    assert [^first_id] =
             repo().all(from(e in Event, where: e.stream_id == ^first.stream_id, select: e.id))

    assert {:ok, %{"results" => [rejected, accepted]}} =
             Ingest.ingest_batch(auth, %{
               "batch_id" => "stream-project-partial-ack",
               "host_id" => "host-1",
               "events" => [project_b, compatible_a]
             })

    assert rejected == %{
             "event_id" => project_b["event_id"],
             "status" => "rejected",
             "retryable" => false,
             "reason" => "stream_metadata_conflict"
           }

    assert accepted["event_id"] == compatible_a["event_id"]
    assert accepted["status"] == "accepted"
    assert %Stream{project: "project-a", next_sequence: 3} = repo().get!(Stream, first.stream_id)

    assert repo().all(
             from(e in Event,
               where: e.stream_id == ^first.stream_id,
               order_by: e.sequence,
               select: e.project
             )
           ) == ["project-a", "project-a"]
  end

  test "only known transient database results are retryable" do
    event = valid_event()
    batch = %{"batch_id" => "postgres", "host_id" => "host-1", "events" => [event]}

    for code <- [:serialization_failure, :deadlock_detected, :query_canceled, :connection_failure] do
      Process.put(:postgres_error_code, code)

      assert {:ok, %{"results" => [%{"status" => "failed", "retryable" => true}]}} =
               Ingest.ingest_batch(auth_context("host-1"), batch,
                 store: Backplane.Memory.IngestTest.PostgresStore
               )
    end

    Process.put(:postgres_error_code, :unique_violation)

    assert_raise RuntimeError, ~r/unexpected event store error/, fn ->
      Ingest.ingest_batch(auth_context("host-1"), batch,
        store: Backplane.Memory.IngestTest.PostgresStore
      )
    end

    Process.put(:postgres_error_code, :serialization_failure)

    assert {:ok, %{"results" => [%{"status" => "failed", "retryable" => true}]}} =
             Ingest.ingest_batch(auth_context("host-1"), batch,
               store: Backplane.Memory.IngestTest.RaisingPostgresStore
             )

    Process.put(:postgres_error_code, :unique_violation)

    assert_raise Postgrex.Error, fn ->
      Ingest.ingest_batch(auth_context("host-1"), batch,
        store: Backplane.Memory.IngestTest.RaisingPostgresStore
      )
    end

    Process.delete(:postgres_error_code)
  end

  test "raised batch connection failures preserve per-event partial ACK semantics" do
    accepted = valid_event()
    future = valid_event(%{"schema_version" => 2})

    assert {:ok, %{"results" => [failed, rejected]}} =
             Ingest.ingest_batch(
               auth_context("host-1"),
               %{
                 "batch_id" => "raised-batch-connection",
                 "host_id" => "host-1",
                 "events" => [accepted, future]
               },
               store: Backplane.Memory.IngestTest.RaisingBatchConnectionStore
             )

    assert failed == %{
             "event_id" => accepted["event_id"],
             "status" => "failed",
             "retryable" => true,
             "reason" => "storage_error"
           }

    assert rejected == %{
             "event_id" => future["event_id"],
             "status" => "rejected",
             "retryable" => false,
             "reason" => "unsupported_schema"
           }
  end

  test "raised batch Postgrex failures are retryable only for known transient codes" do
    event = valid_event()
    batch = %{"batch_id" => "raised-postgres-batch", "host_id" => "host-1", "events" => [event]}

    Process.put(:postgres_error_code, :serialization_failure)

    assert {:ok, %{"results" => [%{"status" => "failed", "retryable" => true}]}} =
             Ingest.ingest_batch(auth_context("host-1"), batch,
               store: Backplane.Memory.IngestTest.RaisingBatchPostgresStore
             )

    Process.put(:postgres_error_code, :unique_violation)

    assert_raise Postgrex.Error, fn ->
      Ingest.ingest_batch(auth_context("host-1"), batch,
        store: Backplane.Memory.IngestTest.RaisingBatchPostgresStore
      )
    end

    Process.delete(:postgres_error_code)
  end

  test "raised batch programmer errors still escape" do
    batch = %{"batch_id" => "buggy-batch", "host_id" => "host-1", "events" => [valid_event()]}

    assert_raise RuntimeError, "batch programmer bug", fn ->
      Ingest.ingest_batch(auth_context("host-1"), batch,
        store: Backplane.Memory.IngestTest.BuggyBatchStore
      )
    end
  end

  defp auth_context(host_id, overrides \\ %{}) do
    Map.merge(
      %{
        host_id: host_id,
        auth_token_id: "token-1",
        scopes: ["host_agent.capture"],
        partition: trusted_partition(host_id)
      },
      overrides
    )
  end

  defp trusted_partition(host_id) do
    %{
      host_id: host_id,
      partition_id: "host:#{host_id}",
      scope: "proj_local",
      namespace: "private"
    }
  end

  defmodule RollbackStore do
    def append_tagged(_attrs, _opts), do: {:error, :transaction_rolled_back}
  end

  defmodule BuggyStore do
    def append_tagged(_attrs, _opts), do: raise("programmer bug")
  end

  defmodule ClosedStore do
    def append_tagged(_attrs, _opts), do: {:error, :stream_closed}
  end

  defmodule InvalidStore do
    def append_tagged(_attrs, _opts), do: {:error, Ecto.Changeset.change({%{}, %{}})}
  end

  defmodule PostgresStore do
    def append_tagged(_attrs, _opts) do
      code = Process.get(:postgres_error_code)
      {:error, postgres_error(code)}
    end

    defp postgres_error(code),
      do: %Postgrex.Error{
        postgres: %{code: code, pg_code: "XX000", severity: "ERROR", message: "test error"}
      }
  end

  defmodule RaisingPostgresStore do
    def append_tagged(_attrs, _opts) do
      code = Process.get(:postgres_error_code)

      raise %Postgrex.Error{
        postgres: %{code: code, pg_code: "XX000", severity: "ERROR", message: "test error"}
      }
    end
  end

  defmodule RaisingBatchConnectionStore do
    def append_batch_tagged(_attrs, _opts) do
      raise DBConnection.ConnectionError, message: "batch database unavailable"
    end
  end

  defmodule RaisingBatchPostgresStore do
    def append_batch_tagged(_attrs, _opts) do
      code = Process.get(:postgres_error_code)

      raise %Postgrex.Error{
        postgres: %{code: code, pg_code: "XX000", severity: "ERROR", message: "test error"}
      }
    end
  end

  defmodule BuggyBatchStore do
    def append_batch_tagged(_attrs, _opts), do: raise("batch programmer bug")
  end
end
