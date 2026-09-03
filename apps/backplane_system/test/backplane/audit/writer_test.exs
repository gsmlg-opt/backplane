defmodule Backplane.Audit.WriterTest do
  use BackplaneSystem.AuditCase, async: false

  import Ecto.Query

  alias Backplane.Audit
  alias Backplane.Audit.{Buffer, SkillLoadLog, ToolCallLog, Writer}
  alias Backplane.Repo

  @moduletag audit_writer: true

  describe "tool audit" do
    test "persists tool call rows with correlation fields" do
      assert :ok =
               Writer.enqueue(%{
                 type: :tool_call,
                 event_id: "evt-audit-tool-001",
                 request_id: "req-001",
                 trace_id: "trace-001",
                 mcp_request_id: "mcp-001",
                 tool_name: "docs::query-docs",
                 status: "ok",
                 duration_us: 5000,
                 arguments_hash: Audit.hash_arguments(%{"query" => "secret"})
               })

      flush_audit!()

      assert [%ToolCallLog{} = log] =
               Repo.all(from(t in ToolCallLog, where: t.event_id == ^"evt-audit-tool-001"))

      assert log.request_id == "req-001"
      assert log.trace_id == "trace-001"
      assert log.mcp_request_id == "mcp-001"
      assert log.tool_name == "docs::query-docs"
      assert log.status == "ok"
      refute log.arguments_hash == ""
      refute inspect(log) =~ "secret"
    end
  end

  describe "skill audit" do
    test "persists skill load rows" do
      assert :ok =
               Audit.log_skill_load(%{
                 event_id: "evt-audit-skill-001",
                 skill_name: "elixir-review",
                 client_name: "test-client",
                 loaded_deps: ["base-lib"]
               })

      flush_audit!()

      assert [%SkillLoadLog{} = log] =
               Repo.all(from(s in SkillLoadLog, where: s.event_id == ^"evt-audit-skill-001"))

      assert log.skill_name == "elixir-review"
      assert log.client_name == "test-client"
      assert log.loaded_deps == ["base-lib"]
    end
  end

  describe "duplicate audit" do
    test "ignores duplicate event_id rows" do
      row = %{
        type: :tool_call,
        event_id: "evt-audit-dup-001",
        tool_name: "git::repo-tree",
        status: "ok"
      }

      assert :ok = Writer.enqueue(row)
      assert :ok = Writer.enqueue(row)
      flush_audit!()

      assert [%ToolCallLog{}] =
               Repo.all(from(t in ToolCallLog, where: t.event_id == ^row.event_id))

      health = Writer.health()
      assert health.duplicate_total >= 1
    end
  end

  describe "writer restart" do
    test "continues accepting events after restart" do
      pid = Process.whereis(Writer)
      assert is_pid(pid)
      ref = Process.monitor(pid)
      assert :ok = GenServer.stop(pid, :normal, 5_000)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      stop_audit_writer!()
      start_audit_writer!()

      assert :ok =
               Writer.enqueue(%{
                 type: :tool_call,
                 event_id: "evt-audit-restart-002",
                 tool_name: "day::now",
                 status: "ok"
               })

      flush_audit!()

      assert Repo.one(from(t in ToolCallLog, where: t.event_id == ^"evt-audit-restart-002"))
      assert Writer.health().status == :ok
    end
  end

  describe "database failure" do
    test "does not crash the writer process" do
      assert :ok =
               Writer.enqueue(%{
                 type: :tool_call,
                 event_id: "evt-audit-fail-001",
                 status: "ok"
               })

      flush_audit!()

      health = Writer.health()
      assert health.status == :ok
      assert health.failed_total >= 1
    end
  end

  describe "queue overflow" do
    @tag buffer_capacity: 1
    test "drops events when the bounded queue is full" do
      assert :ok =
               Writer.enqueue(%{
                 type: :tool_call,
                 event_id: "evt-audit-full-001",
                 tool_name: "hub::discover",
                 status: "ok"
               })

      assert {:error, :full} =
               Writer.enqueue(%{
                 type: :tool_call,
                 event_id: "evt-audit-full-002",
                 tool_name: "hub::discover",
                 status: "ok"
               })

      flush_audit!()

      health = Writer.health()
      assert health.dropped_total >= 1
    end
  end

  describe "argument hash only" do
    test "schema has no raw arguments field" do
      refute :arguments in ToolCallLog.__schema__(:fields)
      assert :arguments_hash in ToolCallLog.__schema__(:fields)
    end
  end

  describe "health" do
    test "reports buffer and insert totals" do
      assert :ok =
               Writer.enqueue(%{
                 type: :tool_call,
                 event_id: "evt-audit-health-001",
                 tool_name: "math::evaluate",
                 status: "ok"
               })

      flush_audit!()

      health = Writer.health()
      assert health.status == :ok
      assert health.inserted_total >= 1
      assert is_map(health.buffer)
      assert Buffer.health(:audit).status == :ok
    end
  end

  describe "controlled shutdown drain" do
    test "drains queued events on demand" do
      assert :ok =
               Writer.enqueue(%{
                 type: :tool_call,
                 event_id: "evt-audit-drain-001",
                 tool_name: "web::fetch",
                 status: "ok"
               })

      assert :ok = Writer.drain()

      assert Repo.one(from(t in ToolCallLog, where: t.event_id == ^"evt-audit-drain-001"))
    end
  end
end
