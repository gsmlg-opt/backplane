defmodule Backplane.Memory.Distill.ToolBackendTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Record, Records}
  alias Backplane.Memory.Distill.ToolBackend

  @at1 "2026-11-01T10:00:00.000000Z"
  @at2 "2026-11-01T10:05:00.000000Z"

  setup do
    e1 = Ecto.UUID.generate()
    e2 = Ecto.UUID.generate()

    chunk = [
      %{
        "event_id" => e1,
        "at" => @at1,
        "type" => "tool_use",
        "tool" => "Bash",
        "content" => "ls"
      },
      %{"event_id" => e2, "at" => @at2, "type" => "tool_use", "tool" => "Bash", "content" => "cd"}
    ]

    session = %{
      subject_id: "subj-1",
      host_id: "host-a",
      session_id: "sess-1",
      agent_id: "claude",
      integration: "claude_code",
      mode: "distill"
    }

    ctx = ToolBackend.context(session, chunk, "distill")
    %{ctx: ctx, e1: e1, e2: e2, chunk: chunk, session: session}
  end

  defp call(ctx, tool, args),
    do: ToolBackend.execute(%{tool_name: tool, arguments: args, backend_context: ctx})

  defp text({:ok, %{content: content}}), do: content

  defp decoded(result), do: result |> text() |> Jason.decode!()

  defp fact_args(e_ids, overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "fact",
        "content" => "repo backplane lives at ~/Workspace/backplane on host-a",
        "subjects" => [
          %{"type" => "repo", "key" => "backplane"},
          %{"type" => "host", "key" => "host-a"}
        ],
        "property" => "path",
        "source_event_ids" => e_ids
      },
      overrides
    )
  end

  test "describes five tools with schema and safety", %{ctx: ctx} do
    descriptors = ToolBackend.descriptors(ctx)

    assert Enum.map(descriptors, & &1.tool_name) == ToolBackend.tool_names()

    assert ToolBackend.tool_names() ==
             ~w(read_chunk search_memory write_memory replace_memory forget_memory)

    for d <- descriptors do
      assert d.backend == ToolBackend
      assert d.schema["type"] == "object"
      assert is_binary(d.description)
      assert Map.has_key?(d.safety, :read_only)
    end

    read_only = Map.new(descriptors, &{&1.tool_name, &1.safety.read_only})

    assert read_only == %{
             "read_chunk" => true,
             "search_memory" => true,
             "write_memory" => false,
             "replace_memory" => false,
             "forget_memory" => false
           }
  end

  test "read_chunk returns the chunk observations", %{ctx: ctx, chunk: chunk} do
    assert %{"observations" => ^chunk} = decoded(call(ctx, "read_chunk", %{}))
  end

  test "read_chunk in review mode includes the session's agent-written records",
       %{session: session, chunk: chunk} do
    {:ok, own} =
      Records.remember(%{
        "kind" => "worklog",
        "content" => "working agent note",
        "writer" => "agent",
        "host_id" => "host-a",
        "session_id" => "sess-1"
      })

    ctx = ToolBackend.context(session, chunk, "review")
    body = decoded(call(ctx, "read_chunk", %{}))

    assert [%{"id" => id}] = body["agent_written"]
    assert id == own.id
  end

  test "an invalid fact returns an error text and stores nothing", %{ctx: ctx, e1: e1} do
    no_property = call(ctx, "write_memory", fact_args([e1], %{"property" => nil}))
    assert {:ok, %{content: "error: " <> _}} = no_property

    no_subjects = call(ctx, "write_memory", fact_args([e1], %{"subjects" => []}))
    assert {:ok, %{content: "error: " <> _}} = no_subjects

    bad_kind = call(ctx, "write_memory", fact_args([e1], %{"kind" => "note"}))
    assert {:ok, %{content: "error: " <> _}} = bad_kind

    garbage = call(ctx, "write_memory", %{"kind" => 5, "content" => nil})
    assert {:ok, %{content: "error: " <> _}} = garbage

    assert repo().aggregate(Record, :count) == 0
    assert :counters.get(ctx.written, 1) == 0
  end

  test "source ids outside the chunk are rejected", %{ctx: ctx, e1: e1} do
    outside = call(ctx, "write_memory", fact_args([e1, Ecto.UUID.generate()]))
    assert {:ok, %{content: "error: " <> _}} = outside

    empty = call(ctx, "write_memory", fact_args([]))
    assert {:ok, %{content: "error: " <> _}} = empty

    assert repo().aggregate(Record, :count) == 0
  end

  test "a valid fact carries memory_agent writer, provenance and source ids",
       %{ctx: ctx, e1: e1, e2: e2} do
    body = decoded(call(ctx, "write_memory", fact_args([e1, e2])))
    record = repo().get!(Record, body["id"])

    assert record.writer == "memory_agent"
    assert record.kind == "fact"
    assert record.host_id == "host-a"
    assert record.agent_id == "claude"
    assert record.integration == "claude_code"
    assert record.session_id == "sess-1"
    assert Enum.sort(record.source_event_ids) == Enum.sort([e1, e2])
    assert DateTime.to_iso8601(record.observed_at) == @at2
    assert "distill:subj-1:" <> _hex = record.request_key
    assert :counters.get(ctx.written, 1) == 1
  end

  test "repeated identical writes produce one record", %{ctx: ctx, e1: e1, e2: e2} do
    first = decoded(call(ctx, "write_memory", fact_args([e1])))
    # A retried run may cite different events for the same candidate.
    second = decoded(call(ctx, "write_memory", fact_args([e2])))

    assert first["id"] == second["id"]
    assert repo().aggregate(Record, :count) == 1
    assert :counters.get(ctx.written, 1) == 1
  end

  test "replace_memory supersedes an active procedure", %{ctx: ctx, e1: e1, e2: e2} do
    old =
      decoded(
        call(ctx, "write_memory", %{
          "kind" => "procedure",
          "content" => "deploy with make deploy",
          "source_event_ids" => [e1]
        })
      )

    new =
      decoded(
        call(ctx, "replace_memory", %{
          "id" => old["id"],
          "kind" => "procedure",
          "content" => "deploy with make deploy; needs VPN on host-a",
          "source_event_ids" => [e2]
        })
      )

    assert repo().get!(Record, old["id"]).status == "superseded"
    assert repo().get!(Record, old["id"]).superseded_by == new["id"]
    assert repo().get!(Record, new["id"]).writer == "memory_agent"
    assert :counters.get(ctx.written, 1) == 2
  end

  test "replace_memory rejects worklogs, inactive and unknown records", %{ctx: ctx, e1: e1} do
    worklog =
      decoded(
        call(ctx, "write_memory", %{
          "kind" => "worklog",
          "content" => "fixed the build",
          "source_event_ids" => [e1]
        })
      )

    args = %{"kind" => "procedure", "content" => "x", "source_event_ids" => [e1]}

    assert {:ok, %{content: "error: " <> _}} =
             call(ctx, "replace_memory", Map.put(args, "id", worklog["id"]))

    assert {:ok, %{content: "error: " <> _}} =
             call(ctx, "replace_memory", Map.put(args, "id", Ecto.UUID.generate()))

    assert {:ok, %{content: "error: " <> _}} =
             call(ctx, "replace_memory", Map.put(args, "id", "not-a-uuid"))
  end

  test "search_memory returns other hosts' records", %{ctx: ctx} do
    {:ok, other} =
      Records.remember(%{
        "kind" => "fact",
        "content" => "postgres listens on port 5432 on host-b",
        "subjects" => [%{"type" => "host", "key" => "host-b"}],
        "property" => "postgres_port",
        "writer" => "agent",
        "host_id" => "host-b"
      })

    body = decoded(call(ctx, "search_memory", %{"query" => "postgres"}))

    assert [%{"id" => id, "provenance" => %{"host" => "host-b"}}] = body["results"]
    assert id == other.id

    assert %{"results" => []} =
             decoded(call(ctx, "search_memory", %{"query" => "postgres", "kind" => "procedure"}))
  end

  test "forget_memory requires a reason and forgets the duplicate", %{ctx: ctx, e1: e1} do
    rec =
      decoded(
        call(ctx, "write_memory", %{
          "kind" => "worklog",
          "content" => "dup",
          "source_event_ids" => [e1]
        })
      )

    assert {:ok, %{content: "error: " <> _}} = call(ctx, "forget_memory", %{"id" => rec["id"]})

    assert %{"status" => "forgotten"} =
             decoded(call(ctx, "forget_memory", %{"id" => rec["id"], "reason" => "duplicate"}))

    assert repo().get!(Record, rec["id"]).forgotten_reason == "duplicate"

    assert {:ok, %{content: "error: " <> _}} =
             call(ctx, "forget_memory", %{"id" => Ecto.UUID.generate(), "reason" => "dup"})
  end

  test "unknown tool returns an error text", %{ctx: ctx} do
    assert {:ok, %{content: "error: " <> _}} = call(ctx, "shell", %{})
  end
end
