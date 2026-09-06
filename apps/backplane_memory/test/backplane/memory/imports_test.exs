defmodule Backplane.Memory.ImportsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Imports}
  alias Backplane.Memory.Imports.ImportBatch

  test "records a display-safe import lifecycle and idempotent batch audit" do
    host_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    repo().insert_all("skill_hosts", [
      %{
        id: Ecto.UUID.dump!(host_id),
        name: "import-host-#{host_id}",
        memory_scope: "private",
        inserted_at: now,
        updated_at: now
      }
    ])

    batch_id = Ecto.UUID.generate()

    started = %{
      "protocol" => "host_import.v1",
      "action" => "started",
      "batch_id" => batch_id,
      "integration" => "claude_code",
      "source_format" => "claude_code_jsonl",
      "source_path_fingerprint" => "sha256:" <> String.duplicate("a", 64)
    }

    assert {:ok, %{"batch_id" => ^batch_id, "status" => "started"}} =
             Imports.record(import_partition(host_id), started)

    completed =
      Map.merge(started, %{
        "action" => "completed",
        "discovered_count" => 4,
        "imported_count" => 2,
        "duplicate_count" => 1,
        "rejected_count" => 1
      })

    assert {:ok, %{"status" => "completed"}} =
             Imports.record(import_partition(host_id), completed)

    assert {:ok, %{"status" => "completed"}} =
             Imports.record(import_partition(host_id), completed)

    assert %ImportBatch{
             host_id: ^host_id,
             status: "completed",
             discovered_count: 4,
             imported_count: 2,
             duplicate_count: 1,
             rejected_count: 1,
             source_path_fingerprint: "sha256:" <> _
           } = repo().get!(ImportBatch, batch_id)

    assert length(Audit.list(operation: "memory.import.started")) == 1
    assert length(Audit.list(operation: "memory.import.completed")) == 1
  end

  test "rejects arbitrary local paths before persistence" do
    host_id = Ecto.UUID.generate()

    assert {:error, %Ecto.Changeset{}} =
             Imports.record(import_partition(host_id), %{
               "protocol" => "host_import.v1",
               "action" => "started",
               "batch_id" => Ecto.UUID.generate(),
               "integration" => "claude_code",
               "source_format" => "claude_code_jsonl",
               "source_path_fingerprint" => "/home/operator/.claude/session.jsonl"
             })
  end

  test "failed terminal lifecycle closes and audits a started batch with sanitized error" do
    host_id = insert_host!()
    batch_id = Ecto.UUID.generate()
    started = started_payload(batch_id)
    assert {:ok, _reply} = Imports.record(import_partition(host_id), started)

    assert {:ok, %{"status" => "failed"}} =
             Imports.record(
               import_partition(host_id),
               Map.merge(started, %{
                 "action" => "failed",
                 "discovered_count" => 1,
                 "imported_count" => 0,
                 "duplicate_count" => 0,
                 "rejected_count" => 1,
                 "error" => "spool_error"
               })
             )

    assert %ImportBatch{status: "failed", error: "spool_error", completed_at: %DateTime{}} =
             repo().get!(ImportBatch, batch_id)

    assert length(Audit.list(operation: "memory.import.failed")) == 1
  end

  test "terminal lifecycle rejects another scope or namespace in the same memory space" do
    partition = import_partition(insert_host!())
    batch_id = Ecto.UUID.generate()
    started = started_payload(batch_id)
    assert {:ok, _} = Imports.record(partition, started)

    for action <- ["completed", "failed"], key <- [:scope, :namespace] do
      foreign_partition = Map.put(partition, key, "other")

      terminal =
        Map.merge(started, %{
          "action" => action,
          "discovered_count" => 0,
          "imported_count" => 0,
          "duplicate_count" => 0,
          "rejected_count" => 0
        })

      assert {:error, :host_mismatch} =
               Imports.record(foreign_partition, terminal)

      assert %ImportBatch{status: "started", completed_at: nil} =
               repo().get!(ImportBatch, batch_id)

      assert Audit.list(operation: "memory.import.#{action}") == []
    end
  end

  defp insert_host! do
    host_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    repo().insert_all("skill_hosts", [
      %{
        id: Ecto.UUID.dump!(host_id),
        name: "import-#{host_id}",
        memory_scope: "private",
        inserted_at: now,
        updated_at: now
      }
    ])

    host_id
  end

  defp started_payload(batch_id) do
    %{
      "protocol" => "host_import.v1",
      "action" => "started",
      "batch_id" => batch_id,
      "integration" => "claude_code",
      "source_format" => "claude_code_jsonl",
      "source_path_fingerprint" => "sha256:" <> String.duplicate("c", 64)
    }
  end

  defp import_partition(host_id) do
    canonical_partition(host_id,
      client_id: "host:#{host_id}",
      source_client_id: "host:#{host_id}",
      scope: "private"
    )
  end
end
