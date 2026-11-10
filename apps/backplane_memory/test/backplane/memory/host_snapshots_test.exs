defmodule Backplane.Memory.HostSnapshotsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.{HostSnapshots, Record, Records}

  defp host, do: "host-#{System.unique_integer([:positive])}"

  defp repo_item(path, branch \\ "main", id \\ nil) do
    %{
      "path" => path,
      "repository_id" => id || "github.com/o/" <> Path.basename(path),
      "branch" => branch,
      "head" => nil
    }
  end

  defp snapshot!(host, items, opts \\ []) do
    occurred_at = Keyword.get(opts, :at, ~U[2026-11-09 10:00:00.000000Z])

    payload =
      Keyword.get(opts, :payload, %{
        "collector" => "git",
        "unit" => "/work",
        "complete" => Keyword.get(opts, :complete, true),
        "items" => items
      })

    {:ok, event} =
      Store.append(%{
        stream_id: "host_collector:#{host}:#{System.unique_integer([:positive])}",
        event_type: "host.snapshot.collected",
        host_id: host,
        agent_id: "host-collector",
        integration: "host_collector",
        payload: payload,
        occurred_at: occurred_at
      })

    event
  end

  defp collector_facts(host, status \\ nil) do
    Record
    |> where([r], r.host_id == ^host and r.writer == "host_collector")
    |> then(fn q -> if status, do: where(q, [r], r.status == ^status), else: q end)
    |> repo().all()
  end

  test "first snapshot writes host_collector facts with provenance" do
    h = host()
    event = snapshot!(h, [repo_item("/work/a"), repo_item("/work/b")])

    assert {:ok, %{written: 2, forgotten: 0}} = HostSnapshots.apply(event)

    facts = collector_facts(h)
    assert length(facts) == 2

    for f <- facts do
      assert f.kind == "fact"
      assert f.writer == "host_collector"
      assert f.integration == "host_collector"
      assert f.source_event_ids == [event.id]
      assert f.observed_at == event.occurred_at
    end
  end

  test "identical content with a newer timestamp writes nothing" do
    h = host()
    items = [repo_item("/work/a")]
    assert {:ok, %{written: 1}} = HostSnapshots.apply(snapshot!(h, items))

    later = snapshot!(h, items, at: ~U[2026-11-09 11:00:00.000000Z])
    assert {:ok, %{written: 0, forgotten: 0}} = HostSnapshots.apply(later)
    assert length(collector_facts(h)) == 1
  end

  test "a branch change rewrites only the checkout fact and supersedes the old one" do
    h = host()
    head = %{"commit" => "abcdef123456", "subject" => "init", "committed_at" => "2026-11-01"}
    item = %{repo_item("/work/a") | "head" => head}
    assert {:ok, %{written: 2}} = HostSnapshots.apply(snapshot!(h, [item]))

    changed = %{item | "branch" => "dev"}

    assert {:ok, %{written: 1, forgotten: 0}} =
             HostSnapshots.apply(snapshot!(h, [changed], at: ~U[2026-11-09 11:00:00.000000Z]))

    assert [%{property: "git_checkout"}] = collector_facts(h, "superseded")
    assert length(collector_facts(h, "active")) == 2
  end

  test "complete snapshot missing a repo forgets its facts with the reason" do
    h = host()

    assert {:ok, %{written: 2}} =
             HostSnapshots.apply(snapshot!(h, [repo_item("/work/a"), repo_item("/work/b")]))

    assert {:ok, %{written: 0, forgotten: 1}} =
             HostSnapshots.apply(
               snapshot!(h, [repo_item("/work/a")], at: ~U[2026-11-09 11:00:00.000000Z])
             )

    assert [forgotten] = collector_facts(h, "forgotten")
    assert {:ok, %{record: record}} = Records.get(forgotten.id)
    assert record.forgotten_reason == "no longer present in host collector snapshot (git:/work)"
  end

  test "incomplete snapshot keeps absent slots until a later complete one" do
    h = host()

    assert {:ok, %{written: 2}} =
             HostSnapshots.apply(snapshot!(h, [repo_item("/work/a"), repo_item("/work/b")]))

    partial =
      snapshot!(h, [repo_item("/work/a")], complete: false, at: ~U[2026-11-09 11:00:00.000000Z])

    assert {:ok, %{written: 0, forgotten: 0}} = HostSnapshots.apply(partial)
    assert collector_facts(h, "forgotten") == []

    complete = snapshot!(h, [repo_item("/work/a")], at: ~U[2026-11-09 12:00:00.000000Z])
    assert {:ok, %{written: 0, forgotten: 1}} = HostSnapshots.apply(complete)
  end

  test "incomplete snapshot still forgets a stale slot of an item that is present" do
    h = host()
    head = %{"commit" => "abcdef123456", "subject" => "init", "committed_at" => "2026-11-01"}

    assert {:ok, %{written: 2}} =
             HostSnapshots.apply(snapshot!(h, [%{repo_item("/work/a") | "head" => head}]))

    partial =
      snapshot!(h, [repo_item("/work/a")], complete: false, at: ~U[2026-11-09 11:00:00.000000Z])

    assert {:ok, %{written: 0, forgotten: 1}} = HostSnapshots.apply(partial)
  end

  test "an agent fact with the same slot is never forgotten" do
    h = host()
    assert {:ok, %{written: 1}} = HostSnapshots.apply(snapshot!(h, [repo_item("/work/a")]))
    [collected] = collector_facts(h)

    {:ok, agent_fact} =
      %Record{}
      |> Record.changeset(%{
        "kind" => "fact",
        "writer" => "agent",
        "host_id" => h,
        "subjects" => collected.subjects,
        "subject_keys" => collected.subject_keys,
        "property" => collected.property,
        "content" => "agent says so",
        "status" => "active",
        "observed_at" => DateTime.utc_now()
      })
      |> repo().insert()

    assert {:ok, %{forgotten: 1}} =
             HostSnapshots.apply(snapshot!(h, [], at: ~U[2026-11-09 11:00:00.000000Z]))

    assert repo().get(Record, agent_fact.id).status == "active"
  end

  test "a user-forgotten collector fact is not rewritten while its content is unchanged" do
    h = host()
    items = [repo_item("/work/a")]
    assert {:ok, %{written: 1}} = HostSnapshots.apply(snapshot!(h, items))
    [fact] = collector_facts(h)
    {:ok, _} = Records.forget(fact.id, "user said no")

    assert {:ok, %{written: 0, forgotten: 0}} =
             HostSnapshots.apply(snapshot!(h, items, at: ~U[2026-11-09 11:00:00.000000Z]))

    assert collector_facts(h, "active") == []
  end

  test "an older snapshot after a newer one is stale and changes nothing" do
    h = host()
    newer = snapshot!(h, [repo_item("/work/a")], at: ~U[2026-11-09 12:00:00.000000Z])
    assert {:ok, %{written: 1}} = HostSnapshots.apply(newer)

    older = snapshot!(h, [repo_item("/work/b")], at: ~U[2026-11-09 11:00:00.000000Z])
    assert {:ok, :stale} = HostSnapshots.apply(older)
    assert {:ok, :stale} = HostSnapshots.apply(newer)

    assert [only] = collector_facts(h)
    assert only.status == "active"
  end

  test "a snapshot from a clock-ahead host does not make later snapshots stale" do
    h = host()
    ahead = DateTime.add(DateTime.utc_now(), 3600, :second)

    assert {:ok, %{written: 1}} =
             HostSnapshots.apply(snapshot!(h, [repo_item("/work/a")], at: ahead))

    Process.sleep(5)
    correct = snapshot!(h, [], at: DateTime.utc_now())
    assert {:ok, %{written: 0, forgotten: 1}} = HostSnapshots.apply(correct)
  end

  test "invalid payloads return an error and write nothing" do
    h = host()

    for payload <- [
          %{"collector" => "nope", "unit" => "x", "complete" => true, "items" => []},
          %{
            "collector" => "git",
            "unit" => "/w",
            "complete" => true,
            "items" => [%{"path" => 1}]
          },
          %{
            "collector" => "git",
            "unit" => "/w",
            "complete" => true,
            "items" => [
              %{"path" => "/w/a", "repository_id" => nil, "branch" => nil, "head" => %{"x" => 1}}
            ]
          }
        ] do
      assert {:error, _} = HostSnapshots.apply(snapshot!(h, [], payload: payload))
    end

    assert collector_facts(h) == []

    assert repo().all(Backplane.Memory.HostSnapshots.State) |> Enum.filter(&(&1.host_id == h)) ==
             []
  end
end
